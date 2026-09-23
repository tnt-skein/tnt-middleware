--- Проверки фасада: настройка, общий реестр и отдельные.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware')

--- Обработчик, который всегда отвечает.
---@return string
local function answering()
    return 'ответ'
end

--- Фабрика слоя, который отмечается в следе своим именем.
---@param trail string[]
---@param mark string
---@return fun(options: table): TntMiddlewareFn
local function factory_of(trail, mark)
    return function()
        return function(context, next_layer)
            table.insert(trail, mark)

            return next_layer(context)
        end
    end
end

g.test_configured_layers_and_groups_are_taken_by_the_shared_chain = function()
    local trail = {}

    g.middleware.configure({
        layers = { audit = factory_of(trail, 'аудит') },
        groups = { web = { 'audit', 'request_id' } },
    })

    local request = {}

    t.assert_equals(g.middleware.chain('web'):run(request, answering), 'ответ')
    t.assert_equals(trail, { 'аудит' })
    t.assert_equals(request.request_id, 'запрос-1')
end

g.test_shared_registry_is_one_and_the_same_until_it_is_reconfigured = function()
    -- Объявления отдаются реестром обратно, чтобы идти подряд одной строкой.
    t.assert_equals(g.middleware.register('audit', factory_of({}, 'аудит')), g.middleware.default())
    t.assert_equals(g.middleware.group('web', { 'audit' }), g.middleware.default())

    t.assert_equals(g.middleware.default(), g.middleware.default())
    t.assert_equals(g.middleware.status().groups, { 'web' })
    t.assert_equals(g.middleware.status().layers, {
        'audit',
        'cors',
        'log',
        'request_id',
        'request_id_header',
        'rescue',
        'timing',
    })
end

g.test_reconfiguration_forgets_what_was_declared_before_it = function()
    g.middleware.group('web', { 'log' })
    g.middleware.configure({ tag = 'http' })

    t.assert_equals(g.middleware.status(), {
        tag = 'http',
        layers = { 'cors', 'log', 'request_id', 'request_id_header', 'rescue', 'timing' },
        groups = {},
    })
end

g.test_separate_registry_knows_nothing_about_the_shared_one = function()
    g.middleware.register('audit', factory_of({}, 'аудит'))

    local own = g.middleware.new({ tag = 'panel' })

    t.assert_equals(own:status().layers, { 'cors', 'log', 'request_id', 'request_id_header', 'rescue', 'timing' })
    t.assert_equals(own:status().tag, 'panel')
    t.assert_equals(g.middleware.status().tag, 'tnt.middleware')
end

g.test_mistake_in_the_settings_is_found_at_configuration_and_not_at_the_request = function()
    local line = nil
    local ok, err = pcall(function()
        line = assert(debug.getinfo(1, 'l')).currentline + 1
        g.middleware.configure({ tag = 'моё приложение' })
    end)

    t.assert_equals(ok, false)
    -- Отказ указывает на строку настройки, а не на нутро пакета.
    t.assert_str_contains(tostring(err), ('middleware_test.lua:%d: '):format(line))
    t.assert_str_contains(tostring(err), 'метка журнала — имя журнала')
end

g.test_every_entry_of_the_facade_blames_the_line_that_called_it = function()
    -- Фасад передаёт работу реестру хвостовым вызовом, и отказ объявления
    -- показывает на строку приложения — не на фасад и не на реестр.
    helper.assert_blamed({
        {
            function()
                g.middleware.chain({ 'lgo' })
            end,
            'слой или группа «lgo» не объявлены; объявлены: cors, log, request_id, request_id_header, rescue, timing',
        },
        {
            function()
                g.middleware.register('audit', 'не фабрика')
            end,
            'слой «audit» объявляется фабрикой: функцией (параметры) -> слой, а не string',
        },
        {
            function()
                g.middleware.group('web', 'log')
            end,
            'группа «web» объявляется списком записей, а не string',
        },
        {
            function()
                g.middleware.configure({ layers = 'log' })
            end,
            'слои объявляются таблицей, а не string',
        },
        {
            function()
                g.middleware.new({ groups = { [7] = {} } })
            end,
            'имя слоя или группы — непустая строка, а не «7»',
        },
    })
end

g.test_ready_layers_are_available_to_those_who_build_the_chain_by_hand = function()
    local request = {}
    local layer = g.middleware.layer.request_id({ field = 'trace' })

    t.assert_equals(g.middleware.chain({ layer }):run(request, answering), 'ответ')
    t.assert_equals(request.trace, 'запрос-1')
end

g.test_field_of_the_request_identifier_is_part_of_the_agreement = function()
    local request = {}

    g.middleware.chain('request_id'):run(request, answering)

    t.assert_equals(request[g.middleware.REQUEST_FIELD], 'запрос-1')
end

g.test_client_gets_the_very_number_that_went_into_the_journal = function()
    local request = {}

    local response = g.middleware.chain({ 'request_id_header', 'request_id', 'log' }):run(request, function()
        return { status = 200 }
    end)

    t.assert_equals(response.headers[g.middleware.REQUEST_HEADER], 'запрос-1')
    t.assert_equals(request[g.middleware.REQUEST_FIELD], 'запрос-1')
    t.assert_equals(g.logged('request_id=запрос-1'), true)
end

g.test_client_gets_the_number_even_when_the_request_broke = function()
    local request = {}

    local answer = g.middleware
        .chain({
            'request_id_header',
            'request_id',
            {
                'rescue',
                {
                    respond = function(_, err)
                        return { status = 500, body = tostring(err) }
                    end,
                },
            },
        })
        :run(request, function()
            error('хранилище молчит')
        end)

    -- Ради этого случая слой заголовка и заведён: человеку, у которого
    -- не вышло, есть что назвать, и номер тот же, что в журнале.
    -- Без ответчика у перехвата наверх ушло бы `nil, err`, и класть
    -- заголовок было бы некуда.
    t.assert_equals(answer.status, 500)
    t.assert_equals(answer.headers[g.middleware.REQUEST_HEADER], 'запрос-1')
    t.assert_equals(request[g.middleware.REQUEST_FIELD], 'запрос-1')
    t.assert_equals(g.logged('request_id=запрос-1'), true)
    t.assert_equals(g.logged('запрос сорвался'), true)
end

g.test_answer_of_the_rescue_without_an_answerer_carries_no_number = function()
    local response, err = g.middleware.chain({ 'request_id_header', 'request_id', 'rescue' }):run({}, function()
        error('хранилище молчит')
    end)

    -- Оговорка документа: без ответчика перехват отдаёт отказ, и заголовку
    -- достаётся не ответ, а пустота.
    t.assert_str_contains(helper.fallen(response, err), 'хранилище молчит')
end

g.test_outgoing_request_goes_through_the_same_conveyor = function()
    local sent = {}

    local send = g.middleware
        .chain({
            'request_id',
            function(request, next_layer)
                request.headers['x-request-id'] = request.request_id

                return next_layer(request)
            end,
        })
        :wrap(function(request)
            table.insert(sent, request)

            return { status = 200, body = 'привет' }
        end)

    local response, err = send({
        method = 'GET',
        url = 'https://example.org/customers/7',
        headers = {},
    })

    t.assert_equals(err, nil)
    t.assert_equals(response.status, 200)
    t.assert_equals(#sent, 1)
    t.assert_equals(sent[1].headers['x-request-id'], 'запрос-1')
end
