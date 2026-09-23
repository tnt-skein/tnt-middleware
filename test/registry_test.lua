--- Проверки реестра: объявления слоёв и групп, разбор записей цепочки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware.registry')

--- Фабрика слоя, который отмечается в следе меткой из своих параметров.
---@param trail string[]
---@return fun(options: table): TntMiddlewareFn
local function marking_factory(trail)
    return function(options)
        return function(context, next_layer)
            table.insert(trail, tostring(options.label))

            return next_layer(context)
        end
    end
end

--- Реестр с объявленным слоем `mark` и тем, что просили сверх него.
---@param trail string[]
---@param opts table|nil
---@return TntMiddleware
local function registry_of(trail, opts)
    local settings = { layers = { mark = marking_factory(trail) } }

    for key, value in pairs(opts or {}) do
        settings[key] = value
    end

    return g.middleware.new(settings)
end

--- Проводит пустой контекст через записи, собранные этим реестром.
---@param registry TntMiddleware
---@param entries any
---@return any response
---@return any err
local function run(registry, entries)
    return registry:chain(entries):run({}, function()
        return 'ответ'
    end)
end

g.test_declared_layer_is_taken_into_the_chain_by_its_name = function()
    local trail = {}
    local registry = registry_of(trail)

    t.assert_equals(run(registry, { { 'mark', { label = 'один' } } }), 'ответ')
    t.assert_equals(trail, { 'один' })
end

g.test_one_factory_gives_two_layers_with_different_settings = function()
    local trail = {}
    local chain = registry_of(trail):chain({
        { 'mark', { label = 'своим' }, name = 'own' },
        { 'mark', { label = 'чужим' }, name = 'others' },
    })

    t.assert_equals(chain:names(), { 'own', 'others' })
    t.assert_equals(
        chain:run({}, function()
            return 'ответ'
        end),
        'ответ'
    )
    t.assert_equals(trail, { 'своим', 'чужим' })
end

g.test_group_unfolds_into_its_layers_right_where_it_stands = function()
    local trail = {}

    local registry = registry_of(trail, {
        groups = {
            web = { { 'mark', { label = 'второй' }, name = 'second' }, 'request_id' },
        },
    })

    local chain = registry:chain({
        { 'mark', { label = 'первый' }, name = 'first' },
        'web',
        { 'mark', { label = 'последний' }, name = 'last' },
    })

    t.assert_equals(chain:names(), { 'first', 'second', 'request_id', 'last' })
    t.assert_equals(
        chain:run({}, function()
            return 'ответ'
        end),
        'ответ'
    )
    t.assert_equals(trail, { 'первый', 'второй', 'последний' })
end

g.test_group_may_include_another_group = function()
    local trail = {}

    local registry = registry_of(trail, {
        groups = {
            web = { 'common', { 'mark', { label = 'свой' }, name = 'own' } },
            common = { { 'mark', { label = 'общий' }, name = 'shared' } },
        },
    })

    t.assert_equals(registry:chain('web'):names(), { 'shared', 'own' })
end

g.test_group_that_includes_itself_is_refused = function()
    local registry = registry_of({}, { groups = { web = { 'web' } } })

    t.assert_error_msg_contains('группа «web» включает саму себя', function()
        registry:chain('web')
    end)
end

g.test_two_groups_that_include_each_other_are_refused = function()
    local registry = registry_of({}, {
        groups = { web = { 'api' }, api = { 'web' } },
    })

    t.assert_error_msg_contains('группа «web» включает саму себя', function()
        registry:chain('web')
    end)
end

g.test_group_takes_no_settings = function()
    local registry = registry_of({}, { groups = { web = {} } })

    t.assert_error_msg_contains(
        'группе «web» параметры не передать: их принимают слои по одному',
        function()
            registry:chain({ { 'web', { label = 'нет' } } })
        end
    )
end

g.test_unknown_name_tells_what_is_declared = function()
    local registry = registry_of({}, { groups = { web = {} } })

    t.assert_error_msg_contains(
        'слой или группа «audit» не объявлены; объявлены: '
            .. 'cors, log, mark, request_id, request_id_header, rescue, timing, web',
        function()
            registry:chain('audit')
        end
    )
end

g.test_layer_written_right_in_the_chain_needs_no_declaration = function()
    local trail, marking = helper.trail()
    local chain = registry_of({}):chain({ { marking('свой'), name = 'own' }, marking('ещё') })

    t.assert_equals(chain:names(), { 'own', '№2' })
    t.assert_equals(chain:run({}, helper.handler(trail, 'ответ')), 'ответ')
    t.assert_equals(
        trail,
        { 'свой до', 'ещё до', 'обработчик', 'ещё после', 'свой после' }
    )
end

g.test_layer_written_in_the_chain_takes_no_settings = function()
    local registry = registry_of({})

    local _, marking = helper.trail()

    t.assert_error_msg_contains(
        'слою-функции параметры не передать: их принимает объявленный слой',
        function()
            registry:chain({ { marking('свой'), { label = 'нет' } } })
        end
    )
end

g.test_settings_put_into_the_chain_list_are_told_how_to_be_written = function()
    local registry = registry_of({})

    t.assert_error_msg_contains(
        'в записи цепочки первым идёт слой или его имя, а не nil; '
            .. "слой с параметрами пишется вложенным списком: { { 'имя', { ... } } }",
        function()
            registry:chain({ 'mark', { label = 'мимо' } })
        end
    )
end

g.test_neighbour_layer_is_not_the_settings_of_this_one = function()
    local registry = registry_of({})

    t.assert_error_msg_contains(
        'параметры слоя «mark» — таблица, а не string: соседний слой пишется отдельной записью',
        function()
            registry:chain({ { 'mark', 'log' } })
        end
    )
end

g.test_entry_of_an_unknown_kind_is_refused = function()
    local registry = registry_of({})

    t.assert_error_msg_contains(
        'запись цепочки непонятна: ожидались слой, имя или { имя, параметры }, а не number',
        function()
            registry:chain({ 42 })
        end
    )
end

g.test_layer_is_declared_by_a_factory_and_not_by_a_layer = function()
    t.assert_error_msg_contains(
        'слой «mark» объявляется фабрикой: функцией (параметры) -> слой, а не string',
        function()
            g.middleware.new({ layers = { mark = 'это не фабрика' } })
        end
    )
end

g.test_name_of_a_layer_is_a_non_empty_string = function()
    t.assert_error_msg_contains(
        'имя слоя или группы — непустая строка, а не «»',
        function()
            g.middleware.new():register('', marking_factory({}))
        end
    )
end

g.test_name_of_a_group_is_a_string = function()
    t.assert_error_msg_contains(
        'имя слоя или группы — непустая строка, а не «42»',
        function()
            g.middleware.new():group(42, {})
        end
    )
end

g.test_group_is_declared_by_a_list_of_entries = function()
    t.assert_error_msg_contains(
        'группа «web» объявляется списком записей, а не string',
        function()
            g.middleware.new({ groups = { web = 'log' } })
        end
    )
end

g.test_journal_tag_follows_the_rule_of_journal_names = function()
    -- Метка уходит журналу именем: негодная обязана отказать при заведении
    -- реестра, а не при сборке первого слоя, и указать на строку приложения.
    -- Сверяется сама строка, а не только файл: уровень отказа — часть
    -- договора, и его поломку должна заметить проверка.
    local rule =
        'метка журнала — имя журнала: до 128 байт из латиницы, цифр, точки, подчёркивания и дефиса'

    for _, tag in ipairs({ 42, 'моё приложение', string.rep('t', 129) }) do
        local line = nil
        local ok, err = pcall(function()
            line = assert(debug.getinfo(1, 'l')).currentline + 1
            local registry = g.middleware.new({ tag = tag })

            -- Не хвостовой вызов: иначе кадра этой строки в стеке не было бы.
            return registry
        end)

        local place, text = tostring(err):match('registry_test%.lua:(%d+): (.*)$')

        t.assert_equals(ok, false, tostring(tag))
        t.assert_equals(tonumber(place), line, tostring(err))
        t.assert_equals(text, ('%s, а не %q'):format(rule, tostring(tag)))
    end

    t.assert_equals(g.middleware.new({ tag = string.rep('t', 128) }):status().tag, string.rep('t', 128))
end

g.test_every_entry_of_the_registry_blames_the_line_that_called_it = function()
    -- Проверки стоят на разной глубине — в записи, в группе, в группе
    -- внутри группы, в фильтре, — а место одно: строка, позвавшая вход.
    local unknown = 'слой или группа «lgo» не объявлены; объявлены: '
        .. 'cors, deep, log, mark, request_id, request_id_header, rescue, timing, web'
    local registry = registry_of({}, { groups = { web = { 'lgo' }, deep = { 'web' } } })

    helper.assert_blamed({
        {
            function()
                registry:chain({ 'lgo' })
            end,
            unknown,
        },
        {
            function()
                registry:chain('deep')
            end,
            unknown,
        },
        {
            function()
                registry:chain({ { 'mark', path = '/api/.*' } })
            end,
            'путь в фильтре слоя — начало пути, а не образец: «/api/.*»; `/api` накрывает `/api` и всё под ним',
        },
        {
            function()
                registry:chain({ { 'mark', method = 7 } })
            end,
            'способ в фильтре слоя — имя или непустой список имён, а не «7»',
        },
        {
            function()
                registry:chain({ { 'mark', paths = '/api' } })
            end,
            'в записи цепочки неизвестное поле «paths»; есть name, path, method',
        },
        {
            function()
                registry:register('x', 'не фабрика' --[[@as any]])
            end,
            'слой «x» объявляется фабрикой: функцией (параметры) -> слой, а не string',
        },
        {
            function()
                registry:group('', {})
            end,
            'имя слоя или группы — непустая строка, а не «»',
        },
        {
            function()
                g.middleware.new({ layers = { x = 'не фабрика' } })
            end,
            'слой «x» объявляется фабрикой: функцией (параметры) -> слой, а не string',
        },
    })
end

g.test_factory_that_blames_its_caller_names_the_line_of_the_declaration = function()
    -- Фабрика зовётся под pcall: её `error(текст, 2)` не ложится на строку
    -- реестра, и место приписывает вход — строку объявления цепочки. Тем же
    -- путём слой `cors` называет строку, где его поставили в цепочку.
    local registry = g.middleware.new({
        layers = {
            limited = function(options)
                if type(options.per_minute) ~= 'number' then
                    error('per_minute — число запросов в минуту', 2)
                end

                return function(context, next_layer)
                    return next_layer(context)
                end
            end,
            broken = function()
                return 'это не слой'
            end,
        },
    })

    helper.assert_blamed({
        {
            function()
                registry:chain('limited')
            end,
            'per_minute — число запросов в минуту',
        },
        {
            function()
                registry:chain({ { 'cors', { methods = { 'PUT' } } } })
            end,
            'настройки слоя cors.origins — массив, а не nil',
        },
        {
            function()
                registry:chain('broken')
            end,
            'слой «broken» собрался не функцией, а string',
        },
    })
end

g.test_factory_that_blames_its_own_line_keeps_it_after_the_line_of_the_declaration = function()
    -- Фабрика, бросившая без уровня, называет свою строку сама, и отказ
    -- несёт обе: где слой поставили в цепочку и где он сломался.
    local thrown_at = nil
    local registry = g.middleware.new({
        layers = {
            broken = function()
                thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
                error('фабрика сорвалась')
            end,
        },
    })
    local called_at = nil
    local ok, err = pcall(function()
        called_at = assert(debug.getinfo(1, 'l')).currentline + 1
        registry:chain('broken')
    end)

    local here = assert(debug.getinfo(1, 'S')).short_src

    t.assert_equals(ok, false)
    t.assert_equals(err, ('%s:%d: %s:%d: фабрика сорвалась'):format(here, called_at, here, thrown_at))
end

g.test_factory_thrown_value_that_is_not_a_string_goes_on_untouched = function()
    -- Места у таблицы не бывает, и приписать его некуда: отказ уходит
    -- тем же значением, и вызывающий узнаёт его по полям.
    local thrown = { code = 'broken' }
    local registry = g.middleware.new({
        layers = {
            broken = function()
                error(thrown)
            end,
        },
    })

    local ok, err = pcall(registry.chain, registry, 'broken')

    t.assert_equals(ok, false)
    t.assert_is(err, thrown)
end

g.test_layers_and_groups_are_declared_by_tables = function()
    t.assert_error_msg_contains('слои объявляются таблицей, а не string', function()
        g.middleware.new({ layers = 'log' })
    end)

    t.assert_error_msg_contains('группы объявляются таблицей, а не number', function()
        g.middleware.new({ groups = 7 })
    end)
end

g.test_factory_that_built_not_a_layer_is_refused = function()
    local registry = g.middleware.new({
        layers = {
            broken = function()
                return 'это не слой'
            end,
        },
    })

    t.assert_error_msg_contains('слой «broken» собрался не функцией, а string', function()
        registry:chain('broken')
    end)
end

g.test_journal_tag_reaches_every_layer_built_by_the_registry = function()
    local seen = {}

    local registry = g.middleware.new({
        tag = 'http',
        layers = {
            mark = function(options)
                table.insert(seen, options.tag)

                return function(context, next_layer)
                    return next_layer(context)
                end
            end,
        },
    })

    registry:chain('mark')

    t.assert_equals(seen, { 'http' })
end

g.test_application_may_take_the_name_of_a_ready_layer_for_itself = function()
    local trail = {}

    local registry = g.middleware.new({
        layers = { log = marking_factory(trail) },
    })

    t.assert_equals(run(registry, { { 'log', { label = 'свой журнал' } } }), 'ответ')
    t.assert_equals(trail, { 'свой журнал' })
    t.assert_equals(g.logged('запрос прошёл'), false)
end

g.test_status_tells_what_is_declared_and_nothing_else = function()
    local registry = registry_of({}, { tag = 'http', groups = { web = {}, api = {} } })

    t.assert_equals(registry:status(), {
        tag = 'http',
        layers = { 'cors', 'log', 'mark', 'request_id', 'request_id_header', 'rescue', 'timing' },
        groups = { 'api', 'web' },
    })
end

g.test_registry_without_settings_keeps_the_ready_layers_and_the_default_tag = function()
    t.assert_equals(g.middleware.new():status(), {
        tag = 'tnt.middleware',
        layers = { 'cors', 'log', 'request_id', 'request_id_header', 'rescue', 'timing' },
        groups = {},
    })
end

g.test_registry_answers_with_itself_so_declarations_go_in_a_row = function()
    local registry = g.middleware.new()

    registry:register('mark', marking_factory({})):group('web', { 'mark' })

    t.assert_equals(registry:status().groups, { 'web' })
end

--- Проводит запрос через записи, собранные этим реестром, и отдаёт след.
---@param registry TntMiddleware
---@param entries any
---@param trail string[]
---@param request table
---@return string[] trail Отметки прохода этого запроса
local function trailed(registry, entries, trail, request)
    for _ = 1, #trail do
        table.remove(trail)
    end

    t.assert_equals(
        registry:chain(entries):run(request, function()
            return 'ответ'
        end),
        'ответ'
    )

    return trail
end

g.test_declared_layer_takes_a_filter_from_its_record = function()
    local trail = {}
    local registry = registry_of(trail)
    local entries = {
        { 'mark', { label = 'везде' }, name = 'everywhere' },
        { 'mark', { label = 'api' }, name = 'api', path = '/api' },
        { 'mark', { label = 'записи' }, name = 'writes', method = 'POST' },
    }

    t.assert_equals(
        trailed(registry, entries, trail, { path = '/api/customers', method = 'POST' }),
        { 'везде', 'api', 'записи' }
    )
    t.assert_equals(
        trailed(registry, entries, trail, { path = '/api/customers', method = 'GET' }),
        { 'везде', 'api' }
    )
    t.assert_equals(
        trailed(registry, entries, trail, { path = '/panel', method = 'POST' }),
        { 'везде', 'записи' }
    )
end

g.test_group_taken_with_a_filter_gives_it_to_each_of_its_layers = function()
    -- Слой группы со своим фильтром проходит оба: сузить группу — не
    -- значит снять то, что слой поставил себе.
    local trail = {}
    local registry = registry_of(trail, {
        groups = {
            web = {
                { 'mark', { label = 'общий' }, name = 'shared' },
                { 'mark', { label = 'записи' }, name = 'writes', method = 'POST' },
            },
        },
    })
    local entries = { { 'web', path = '/panel' } }

    t.assert_equals(
        trailed(registry, entries, trail, { path = '/panel/x', method = 'POST' }),
        { 'общий', 'записи' }
    )
    t.assert_equals(trailed(registry, entries, trail, { path = '/panel/x', method = 'GET' }), { 'общий' })
    t.assert_equals(trailed(registry, entries, trail, { path = '/api/x', method = 'POST' }), {})
end

g.test_filter_of_the_record_is_checked_when_the_chain_is_built = function()
    local registry = registry_of({})

    t.assert_error_msg_contains(
        'путь в фильтре слоя — начало пути, а не образец',
        function()
            registry:chain({ { 'mark', { label = 'x' }, path = '/api/.*' } })
        end
    )
    t.assert_error_msg_contains(
        'способ в фильтре слоя — имя или непустой список имён',
        function()
            registry:chain({ { 'mark', { label = 'x' }, method = {} } })
        end
    )
end

g.test_unknown_named_field_of_a_record_is_refused_as_a_misspelt_filter = function()
    -- `paths` вместо `path` иначе прошло бы молча, и слой встал бы на всё.
    local registry = registry_of({})

    t.assert_error_msg_contains(
        'в записи цепочки неизвестное поле «paths»; есть name, path, method',
        function()
            registry:chain({ { 'mark', { label = 'x' }, paths = '/api' } })
        end
    )
    t.assert_error_msg_contains('неизвестное поле «only»', function()
        registry:chain({
            {
                function(_, next_layer)
                    return next_layer()
                end,
                only = { path = '/api' },
            },
        })
    end)
end
