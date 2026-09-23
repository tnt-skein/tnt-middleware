--- Проверки цепочки: порядок прохода, отказ и правка состава на месте.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware.chain')

--- Слой, который ничего не делает, кроме как пускает запрос дальше.
---@param context any
---@param next_layer TntMiddlewareNext
---@return any
---@return any
local function passing(context, next_layer)
    return next_layer(context)
end

--- Проводит контекст через записи до обработчика и обратно.
---@param entries any
---@param handler fun(context: any): any, any
---@param context any|nil
---@return any response
---@return any err
local function run(entries, handler, context)
    return g.middleware.chain(entries):run(context or {}, handler)
end

--- Отказ, который дала цепочка из одной записи.
---@param entry any
---@return string
local function refused(entry)
    local response, err = run({ entry }, function()
        return 'ответ'
    end)

    return helper.refusal(response, err)
end

--- Слово отказа упавшего шага в цепочке из одной записи.
---@param entry any
---@return string
local function fell(entry)
    local response, err = run({ entry }, function()
        return 'ответ'
    end)

    return helper.fallen(response, err)
end

--- Первый кадр стека отказа: с него стек и читают.
---@param err TntMiddlewareFall
---@return string
local function first_frame(err)
    local frame = err.traceback:match('stack traceback:%s*([^\n]+)')

    return (assert(frame, 'в стеке нет ни одного кадра'))
end

g.test_layers_go_top_down_on_the_way_in_and_bottom_up_on_the_way_out = function()
    local trail, marking = helper.trail()

    local response, err = run({ marking('первый'), marking('второй') }, helper.handler(trail, 'ответ'))

    t.assert_equals(response, 'ответ')
    t.assert_equals(err, nil)
    t.assert_equals(trail, {
        'первый до',
        'второй до',
        'обработчик',
        'второй после',
        'первый после',
    })
end

g.test_chain_without_layers_goes_straight_to_the_handler = function()
    local trail = {}

    t.assert_equals(run(nil, helper.handler(trail, 'ответ')), 'ответ')
    t.assert_equals(trail, { 'обработчик' })
end

g.test_single_layer_needs_no_list_around_it = function()
    local trail, marking = helper.trail()

    t.assert_equals(run(marking('один'), helper.handler(trail, 'ответ')), 'ответ')
    t.assert_equals(trail, { 'один до', 'обработчик', 'один после' })
end

g.test_layer_answers_instead_of_the_handler = function()
    local trail = {}

    local response, err = run({
        function()
            return 'из слоя'
        end,
    }, helper.handler(trail, 'ответ'))

    t.assert_equals(response, 'из слоя')
    t.assert_equals(err, nil)
    t.assert_equals(trail, {})
end

g.test_layer_sees_the_response_of_those_below = function()
    local response = run({
        function(context, next_layer)
            return next_layer(context) .. ' и сверху'
        end,
    }, function()
        return 'снизу'
    end)

    t.assert_equals(response, 'снизу и сверху')
end

g.test_next_carries_the_replacement_context_down = function()
    local seen = {}

    local response = run({
        function(context, next_layer)
            local answer = next_layer({ path = '/подменённый' })

            -- Слой выше по цепочке продолжает видеть свой контекст:
            -- подмена уходит вниз, а не в обе стороны.
            table.insert(seen, context.path)

            return answer
        end,
    }, function(context)
        table.insert(seen, context.path)

        return 'ответ'
    end, { path = '/исходный' })

    t.assert_equals(response, 'ответ')
    t.assert_equals(seen, { '/подменённый', '/исходный' })
end

g.test_next_without_an_argument_keeps_the_context = function()
    local seen

    local response = run({
        function(_, next_layer)
            return next_layer()
        end,
    }, function(context)
        seen = context.path

        return 'ответ'
    end, { path = '/тот же' })

    t.assert_equals(response, 'ответ')
    t.assert_equals(seen, '/тот же')
end

g.test_thrown_error_becomes_a_refusal_naming_the_layer = function()
    local said = fell({
        function()
            error('нет места на диске')
        end,
        name = 'проверка',
    })

    t.assert_str_contains(said, 'слой «проверка» упал')
    t.assert_str_contains(said, 'нет места на диске')
end

g.test_unnamed_layer_is_named_by_its_place_in_the_chain = function()
    local response, err = run({
        passing,
        function()
            error({ message = 'нет места на диске' })
        end,
    }, function()
        return 'ответ'
    end)

    t.assert_equals(helper.fallen(response, err), 'слой №2 упал: нет места на диске')
    t.assert_equals(err.message, 'слой №2 упал: нет места на диске')
end

g.test_thrown_table_without_a_message_stays_itself = function()
    local said = fell(function()
        error({ code = 42 })
    end)

    t.assert_str_contains(said, 'слой №1 упал: table: ')
end

g.test_layers_above_the_fallen_one_still_finish_their_way_out = function()
    local trail, marking = helper.trail()

    local response, err = run({
        marking('верхний'),
        function()
            error('беда')
        end,
    }, helper.handler(trail, 'ответ'))

    t.assert_str_contains(helper.fallen(response, err), 'слой №2 упал')
    t.assert_equals(trail, { 'верхний до', 'верхний после' })
end

g.test_fallen_handler_becomes_a_refusal_with_the_stack_of_the_throw = function()
    local thrown_at

    local response, err = run({ passing }, function()
        thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
        error('в хранилище не записалось')
    end)

    t.assert_equals(
        helper.fallen(response, err),
        ('обработчик упал: %s:%d: в хранилище не записалось'):format(
            assert(debug.getinfo(1, 'S')).short_src,
            thrown_at
        )
    )
    -- Стек несёт кадр самого обработчика: по нему видно, как туда пришли,
    -- а слово поломки называет только место броска.
    t.assert_str_contains(err.traceback, ('chain_test.lua:%d: in function'):format(thrown_at))
end

g.test_what_the_handler_threw_reaches_the_caller_inside_the_fall = function()
    -- Отказ, брошенный обработчиком нарочно, доходит до вызывающего
    -- целиком — и тогда, когда слой выше получил его от `next` и бросил
    -- заново: по слову упавшего шага статус и код уже не узнать.
    local refusal = { status = 404, message = 'нет такого клиента' }
    local rethrown_at

    local response, err = run({
        {
            function(context, next_layer)
                local _, below = next_layer(context)

                rethrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
                error(below)
            end,
            name = 'audit',
        },
        passing,
    }, function()
        error(refusal)
    end)

    t.assert_equals(
        helper.fallen(response, err),
        'слой «audit» упал: обработчик упал: нет такого клиента'
    )
    t.assert_is(err.raised, refusal)
    -- Стек — места последнего броска: стеки цепочка не склеивает.
    t.assert_str_contains(err.traceback, ('chain_test.lua:%d: in function'):format(rethrown_at))

    response, err = run({ passing }, function()
        error(refusal)
    end)

    t.assert_equals(helper.fallen(response, err), 'обработчик упал: нет такого клиента')
    t.assert_is(err.raised, refusal)
end

g.test_the_stack_of_the_fall_starts_where_it_broke = function()
    -- Ловушка снимает стек изнутри себя, и без поправки на это первым
    -- кадром стояла бы она сама, а с лишней поправкой — уже не место
    -- поломки. Обращение к пустоте падает без `error`, и первым кадром
    -- обязан стоять тот, кто к ней обратился.
    local broke_at

    local response, err = run({
        function(context)
            local nothing = rawget(context, 'клиент')

            broke_at = assert(debug.getinfo(1, 'l')).currentline + 2

            return nothing.field
        end,
    }, function()
        return 'ответ'
    end)

    helper.fallen(response, err)
    t.assert_str_contains(first_frame(err), ('chain_test.lua:%d:'):format(broke_at))

    response, err = run(nil, function(context)
        local nothing = rawget(context, 'клиент')

        broke_at = assert(debug.getinfo(1, 'l')).currentline + 2

        return nothing.field
    end)

    helper.fallen(response, err)
    t.assert_str_contains(first_frame(err), ('chain_test.lua:%d:'):format(broke_at))
end

g.test_thrown_value_that_cannot_be_printed_still_ends_in_a_refusal = function()
    -- Печать брошенного бросает прямо в ловушке, и `xpcall` отдаёт вместо
    -- отказа слово Lua. Стека тогда нет, но исключение из цепочки
    -- не выходит: вызывающий получает пару, как обещано.
    local unprintable = setmetatable({}, {
        __tostring = function()
            error('печать сломана')
        end,
    })

    local response, err = run({ passing }, function()
        error(unprintable)
    end)

    t.assert_equals(helper.refusal(response, err), 'error in error handling')
end

g.test_handler_that_returns_nothing_is_a_refusal = function()
    local response, err = run({ passing }, function() end)

    t.assert_equals(
        helper.refusal(response, err),
        'обработчик не вернул ни ответа, ни причины отказа'
    )
end

g.test_layer_that_forgot_next_is_named_together_with_its_mistake = function()
    local err = refused({ function() end, name = 'забывчивый' })

    t.assert_equals(
        err,
        'слой «забывчивый» не позвал next и не вернул ответа: '
            .. 'запрос дальше не пошёл, а отвечать нечем'
    )
end

g.test_layer_that_lost_the_response_is_named_together_with_its_mistake = function()
    local err = refused({
        function(context, next_layer)
            next_layer(context)
        end,
        name = 'потерявший',
    })

    t.assert_equals(
        err,
        'слой «потерявший» позвал next, но не вернул ответ: остаток цепочки отработал впустую'
    )
end

g.test_layer_may_lead_the_request_through_the_rest_of_the_chain_again = function()
    local attempts = 0

    local response, err = run({
        function(context, next_layer)
            local answer, failure = next_layer(context)

            if failure == nil then
                return answer
            end

            -- Так устроен повтор: слой ведёт запрос по остатку цепочки
            -- заново, и это должно быть можно.
            return next_layer(context)
        end,
    }, function()
        attempts = attempts + 1

        if attempts == 1 then
            return nil, 'хранилище молчит'
        end

        return 'ответ со второй попытки'
    end)

    t.assert_equals(err, nil)
    t.assert_equals(response, 'ответ со второй попытки')
    t.assert_equals(attempts, 2)
end

g.test_refusal_from_below_reaches_the_caller_untouched = function()
    local response, err = run({ passing }, function()
        return nil, 'хранилище молчит'
    end)

    t.assert_equals(helper.refusal(response, err), 'хранилище молчит')
end

g.test_named_layers_keep_their_names_and_unnamed_ones_their_places = function()
    local chain = g.middleware.chain({ { passing, name = 'первый' }, passing })

    t.assert_equals(chain:names(), { 'первый', '№2' })
end

g.test_layer_that_is_not_in_the_chain_cannot_be_moved = function()
    local chain = g.middleware.chain({ { passing, name = 'первый' }, passing })

    t.assert_error_msg_contains(
        'в цепочке нет слоя «опечатка»; есть: первый, №2',
        function()
            chain:without('опечатка')
        end
    )
end

g.test_layer_goes_before_after_or_out_of_the_chain_by_name = function()
    local trail, marking = helper.trail()

    local chain = g.middleware.chain({
        { marking('первый'), name = 'первый' },
        { marking('второй'), name = 'второй' },
    })

    t.assert_is(
        chain:before('второй', { marking('вставленный'), name = 'вставленный' }),
        chain
    )
    t.assert_equals(chain:names(), { 'первый', 'вставленный', 'второй' })

    t.assert_is(chain:after('первый', { marking('ранний'), name = 'ранний' }), chain)
    t.assert_equals(chain:names(), { 'первый', 'ранний', 'вставленный', 'второй' })

    t.assert_is(chain:without('первый'), chain, 'правка отвечает той же цепочкой')
    t.assert_equals(chain:names(), { 'ранний', 'вставленный', 'второй' })
    t.assert_equals(chain:run({}, helper.handler(trail, 'ответ')), 'ответ')
    t.assert_equals(trail, {
        'ранний до',
        'вставленный до',
        'второй до',
        'обработчик',
        'второй после',
        'вставленный после',
        'ранний после',
    })
end

g.test_every_entry_of_the_chain_blames_the_line_that_called_it = function()
    -- Методы цепочки друг друга не зовут: второй вход приписал бы второе
    -- место. Поэтому место у каждого одно — строка, позвавшая метод.
    local chain = g.middleware.chain({ { passing, name = 'первый' }, { passing, name = 'второй' } })
    local missing = 'в цепочке нет слоя «опечатка»; есть: первый, второй'
    local taken = 'слой «первый» в цепочке уже есть'
    local no_handler =
        'цепочке нужен обработчик: функция (context) -> ответ, отказ'

    helper.assert_blamed({
        {
            function()
                chain:without('опечатка')
            end,
            missing,
        },
        {
            function()
                chain:before('опечатка', passing)
            end,
            missing,
        },
        {
            function()
                chain:after('опечатка', passing)
            end,
            missing,
        },
        {
            function()
                chain:index_of('опечатка')
            end,
            missing,
        },
        {
            function()
                chain:before('второй', { passing, name = 'первый' })
            end,
            taken,
        },
        {
            function()
                chain:use({ passing, name = 'первый' })
            end,
            taken,
        },
        {
            function()
                chain:insert(1, 'lgo')
            end,
            'слой или группа «lgo» не объявлены; объявлены: cors, log, request_id, request_id_header, rescue, timing',
        },
        {
            function()
                chain:use(passing, { path = '/api' })
            end,
            "фильтр слоя пишется в самой записи: { слой, path = '/api', method = 'GET' }",
        },
        {
            function()
                chain:wrap('это не функция')
            end,
            no_handler,
        },
        {
            function()
                chain:run({}, 'это не функция')
            end,
            no_handler,
        },
    })

    -- Промахи не тронули состав, а место названного слоя — его номер.
    t.assert_equals(chain:names(), { 'первый', 'второй' })
    t.assert_equals(chain:index_of('второй'), 2)

    -- Вставка на место отвечает той же цепочкой, как и прочие правки.
    t.assert_is(chain:insert(2, { passing, name = 'вставленный' }), chain)
    t.assert_equals(chain:names(), { 'первый', 'вставленный', 'второй' })
end

g.test_name_taken_in_the_chain_is_not_given_twice = function()
    local chain = g.middleware.chain({ { passing, name = 'журнал' } })

    t.assert_error_msg_contains('слой «журнал» в цепочке уже есть', function()
        chain:use({ passing, name = 'журнал' })
    end)
end

g.test_copy_of_the_chain_is_changed_apart_from_the_original = function()
    local chain = g.middleware.chain({ { passing, name = 'общий' } })
    local copy = chain:clone()

    copy:use({ passing, name = 'свой' })

    t.assert_equals(chain:names(), { 'общий' })
    t.assert_equals(copy:names(), { 'общий', 'свой' })
end

g.test_chain_changed_after_wrapping_works_by_its_new_composition = function()
    local trail, marking = helper.trail()
    local chain = g.middleware.chain()
    local handle = chain:wrap(helper.handler(trail, 'ответ'))

    chain:use(marking('поздний'))

    t.assert_equals(handle({}), 'ответ')
    t.assert_equals(trail, { 'поздний до', 'обработчик', 'поздний после' })
end

g.test_chain_shortened_after_wrapping_works_by_its_new_composition = function()
    local trail, marking = helper.trail()
    local chain = g.middleware.chain({ { marking('снимаемый'), name = 'снимаемый' } })
    local handle = chain:wrap(helper.handler(trail, 'ответ'))

    t.assert_equals(handle({}), 'ответ')

    chain:without('снимаемый')

    t.assert_equals(handle({}), 'ответ')
    t.assert_equals(trail, {
        'снимаемый до',
        'обработчик',
        'снимаемый после',
        'обработчик',
    })
end

g.test_layers_that_stood_up_before_a_failed_insertion_are_used_all_the_same = function()
    local trail, marking = helper.trail()

    g.middleware.group('pair', {
        { marking('первый'), name = 'один' },
        { marking('второй'), name = 'один' },
    })

    local chain = g.middleware.chain()
    local handle = chain:wrap(helper.handler(trail, 'ответ'))

    t.assert_equals(handle({}), 'ответ')

    t.assert_error_msg_contains('слой «один» в цепочке уже есть', function()
        chain:use('pair')
    end)

    -- Первый слой группы встать успел, и проход обязан идти через него:
    -- состав после неудачной вставки — тоже новый состав.
    t.assert_equals(chain:names(), { 'один' })
    t.assert_equals(handle({}), 'ответ')
    t.assert_equals(
        trail,
        { 'обработчик', 'первый до', 'обработчик', 'первый после' }
    )
end

g.test_pass_is_built_once_per_composition_and_not_per_request = function()
    local trail, marking = helper.trail()
    local chain = g.middleware.chain({ { marking('прежний'), name = 'прежний' } })
    local handle = chain:wrap(helper.handler(trail, 'ответ'))

    t.assert_equals(handle({}), 'ответ')

    -- Правка в обход методов отметку состава не меняет, и проход,
    -- собранный один раз, идёт по прежнему составу. Собирайся он заново
    -- на каждый запрос — подмена сработала бы сразу, и цена, записанная
    -- в опасных местах, оказалась бы придуманной.
    chain.layers[1] = { fn = marking('подменённый'), name = 'подменённый' }

    t.assert_equals(handle({}), 'ответ')
    t.assert_equals(trail, {
        'прежний до',
        'обработчик',
        'прежний после',
        'прежний до',
        'обработчик',
        'прежний после',
    })

    -- А правка через метод отметку меняет, и тогда виден весь новый
    -- состав — вместе с тем слоем, который подменили в обход.
    chain:use({ marking('поздний'), name = 'поздний' })

    t.assert_equals(handle({}), 'ответ')
    t.assert_equals({ unpack(trail, 7) }, {
        'подменённый до',
        'поздний до',
        'обработчик',
        'поздний после',
        'подменённый после',
    })
end

g.test_chain_without_a_handler_is_an_error_at_once = function()
    t.assert_error_msg_contains('цепочке нужен обработчик', function()
        g.middleware.chain():wrap('это не функция')
    end)
end

g.test_layer_with_a_filter_is_passed_by_only_by_the_requests_that_do_not_match = function()
    local trail, marking = helper.trail()
    local handle = g.middleware
        .chain({
            marking('общий'),
            { marking('api'), name = 'api', path = '/api' },
            { marking('записи'), method = { 'POST', 'PUT' } },
        })
        :wrap(helper.handler(trail, 'ответ'))

    t.assert_equals(handle({ path = '/api/customers', method = 'POST' }), 'ответ')
    t.assert_equals(trail, {
        'общий до',
        'api до',
        'записи до',
        'обработчик',
        'записи после',
        'api после',
        'общий после',
    })

    for _ = 1, #trail do
        table.remove(trail)
    end

    -- Запрос мимо фильтра идёт мимо слоя и на входе, и на выходе:
    -- как будто слоя в цепочке нет.
    t.assert_equals(handle({ path = '/panel', method = 'GET' }), 'ответ')
    t.assert_equals(trail, { 'общий до', 'обработчик', 'общий после' })
end

g.test_filtered_layer_that_is_passed_by_is_not_blamed_for_anything = function()
    -- Пропущенный слой не зовётся — значит, не падает и не теряет ответ;
    -- а на запрос, который проходит фильтр, отказ называет его как всегда.
    local chain = g.middleware.chain({
        {
            function()
                error('в хранилище не записалось')
            end,
            name = 'ломкий',
            path = '/api',
        },
    })
    local handle = chain:wrap(function()
        return 'ответ'
    end)

    t.assert_equals(handle({ path = '/panel' }), 'ответ')
    t.assert_equals(handle({}), 'ответ')

    local response, err = handle({ path = '/api/customers' })

    t.assert_str_contains(helper.fallen(response, err), 'слой «ломкий» упал')
end

g.test_filter_of_the_layer_survives_the_copy_and_the_moves_of_the_chain = function()
    local trail, marking = helper.trail()
    local chain = g.middleware.chain({ { marking('первый'), name = 'первый' } })

    chain:before('первый', { marking('api'), name = 'api', path = '/api' })

    local copy = chain:clone()

    t.assert_equals(copy:names(), { 'api', 'первый' })
    t.assert_equals(copy:run({ path = '/panel' }, helper.handler(trail, 'ответ')), 'ответ')
    t.assert_equals(trail, { 'первый до', 'обработчик', 'первый после' })
end

g.test_filter_as_a_second_argument_of_use_is_refused_and_told_where_to_write_it = function()
    -- Привычка от рока http: `use(handler, { path = … })`. Отбросить
    -- аргумент молча нельзя — слой, задуманный под /api/, встал бы на всё.
    local chain = g.middleware.chain()

    t.assert_error_msg_contains(
        "фильтр слоя пишется в самой записи: { слой, path = '/api', method = 'GET' }",
        function()
            chain:use(passing, { path = '/api' })
        end
    )
    t.assert_equals(chain:names(), {})

    -- А без второго аргумента запись встаёт как всегда.
    t.assert_equals(chain:use({ passing, name = 'один' }):names(), { 'один' })
end
