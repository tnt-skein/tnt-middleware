--- Проверки готовых слоёв: журнал, время ответа, перехват, опознаватель.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware.layer')

--- Обработчик, который всегда отвечает.
---@return string
local function answering()
    return 'ответ'
end

--- Обработчик, который всегда отказывает.
---@return nil
---@return string
local function refusing()
    return nil, 'хранилище молчит'
end

--- Обработчик, отказывающий названным отказом: его и читает приговор.
---@param err any
---@return fun(): nil, any
local function refusing_with(err)
    return function()
        return nil, err
    end
end

--- Обработчик, который отвечает таблицей — в неё есть куда класть заголовки.
---@return table
local function responding()
    return { status = 200 }
end

--- Проводит контекст через одну запись до обработчика и обратно.
---@param entry any
---@param handler fun(context: any): any, any
---@param context any|nil
---@return any response
---@return any err
local function through(entry, handler, context)
    return g.middleware.chain({ entry }):run(context or {}, handler)
end

--- Сверяет, что негодная настройка готового слоя отвергается при сборке
--- и винит строку, которая слой собрала.
---
--- Путей сборки два, и место у обоих своё: слой, собранный руками, винит
--- вызов фабрики, а запись цепочки — строку объявления цепочки. Строка
--- пакета, где настройку сверили, не годится ни тому, ни другому.
---@param name string Имя готового слоя
---@param options table Настройки с одной негодной
---@param text string Текст отказа
local function assert_refused(name, options, text)
    helper.assert_blamed({
        {
            function()
                g.middleware.layer[name](options)
            end,
            text,
        },
        {
            function()
                g.middleware.chain({ { name, options } })
            end,
            text,
        },
    })
end

g.test_log_writes_one_record_about_the_whole_passage = function()
    t.assert_equals(through('log', answering), 'ответ')

    t.assert_equals(g.logged('запрос прошёл'), true)
    t.assert_equals(g.logged('INFO'), true)
    t.assert_equals(g.logged('[tnt.middleware]'), true)
    t.assert_equals(g.logged('seconds=0.5'), true)
end

-- Код ответа берётся из самого ответа: описатель видит только запрос,
-- а строка доступа без кода не говорит, чем запрос кончился.
g.test_log_writes_the_status_of_a_table_response = function()
    t.assert_equals(through('log', responding), { status = 200 })

    t.assert_equals(g.logged('status=200'), true)
end

-- Ответ не таблицей кода не даёт: у строки его нет, и поля в записи нет.
g.test_log_writes_no_status_for_a_response_that_is_not_a_table = function()
    through('log', answering)

    t.assert_equals(g.logged('status='), false)
end

g.test_log_writes_the_level_it_was_told_to = function()
    for _, level in ipairs({ 'debug', 'info', 'warn', 'error' }) do
        t.assert_equals(through({ 'log', { level = level } }, answering), 'ответ')
        t.assert_equals(g.logged(level:upper()), true)
    end
end

g.test_log_refuses_a_level_the_journal_does_not_know = function()
    assert_refused(
        'log',
        { level = 'громко' },
        'журналу неизвестен уровень «громко»'
    )
    assert_refused('log', { level = 5 }, 'журналу неизвестен уровень «5»')
end

g.test_description_of_the_request_is_a_function = function()
    -- Описатель зовётся на каждом запросе под pcall, и не-функция
    -- не уронила бы ни одного: она молча стоила бы записи каждому.
    for _, name in ipairs({ 'log', 'rescue' }) do
        assert_refused(
            name,
            { describe = { path = '/' } },
            'описатель запроса — функция (context) -> поля, а не table'
        )
    end
end

g.test_journal_tag_of_a_layer_follows_the_rule_of_journal_names = function()
    -- Метку слою даёт реестр, а слой, собранный руками, берёт её
    -- настройкой. Текст отказа тот же, что у метки реестра, а место —
    -- строка сборки, а не фабрика слоя, откуда метку взял журнал.
    local refused = 'метка журнала — имя журнала: до 128 байт из латиницы, '
        .. 'цифр, точки, подчёркивания и дефиса, а не "моё приложение"'

    for _, name in ipairs({ 'log', 'timing', 'rescue', 'request_id_header' }) do
        assert_refused(name, { tag = 'моё приложение' }, refused)
    end
end

g.test_layer_built_by_hand_writes_under_its_own_tag = function()
    local layer = g.middleware.layer.log({ tag = 'app.http' })

    t.assert_equals(through(layer, answering), 'ответ')
    t.assert_equals(g.logged('[app.http]'), true)
end

g.test_log_tells_about_a_refusal_but_does_not_swallow_it = function()
    local response, err = through('log', refusing)

    t.assert_equals(helper.refusal(response, err), 'хранилище молчит')
    t.assert_equals(g.logged('запрос не прошёл'), true)
    t.assert_equals(g.logged('WARN'), true)
    t.assert_equals(g.logged('err="хранилище молчит"'), true)
    t.assert_equals(g.logged('запрос прошёл'), false)
end

g.test_log_takes_the_description_of_the_request_from_the_caller = function()
    local describe = function(context)
        return { path = context.path }
    end

    through({ 'log', { describe = describe } }, answering, { path = '/customers/7' })

    t.assert_equals(g.logged('path=/customers/7'), true)
end

-- Опознаватель приходит в запись из контекста файбера верхним полем,
-- а не полем вызывающего: два места для одного значения разошлись бы.
g.test_log_puts_the_request_identifier_into_the_record_from_the_context = function()
    g.middleware.chain({ 'request_id', 'log' }):run({}, answering)

    t.assert_equals(g.logged('request_id=запрос-1'), true)

    local record = g.records()[1].record

    t.assert_equals(record.request_id, 'запрос-1')
    t.assert_equals(record.fields.request_id, nil)
end

g.test_log_without_the_identifier_layer_writes_no_identifier = function()
    through('log', answering, { request_id = 'в запросе, но не в контексте' })

    t.assert_equals(g.logged('request_id='), false)
end

g.test_rescue_and_log_records_carry_the_identifier_on_top = function()
    g.middleware.chain({ 'request_id', 'rescue', 'log' }):run({}, refusing)

    local listed = g.records()

    t.assert_equals(#listed, 2)

    for _, entry in ipairs(listed) do
        t.assert_equals(entry.record.request_id, 'запрос-1', entry.line)
        t.assert_equals(entry.record.fields.request_id, nil, entry.line)
    end
end

g.test_record_that_did_not_get_written_does_not_cost_the_request = function()
    local describe = function()
        error('описатель сорвался')
    end

    t.assert_equals(through({ 'log', { describe = describe } }, answering), 'ответ')
    t.assert_equals(g.logged('записать о запросе не удалось'), true)
    t.assert_equals(g.logged('описатель сорвался'), true)
end

g.test_journal_tag_of_the_registry_marks_the_records_of_ready_layers = function()
    g.middleware.configure({ tag = 'http' })

    through('log', answering)

    t.assert_equals(g.logged('[http]'), true)
end

g.test_timing_puts_the_duration_into_the_context = function()
    local request = {}

    t.assert_equals(through('timing', answering, request), 'ответ')
    t.assert_equals(request.duration, 0.5)
end

g.test_timing_puts_the_duration_where_it_was_told_to = function()
    local request = {}

    through({ 'timing', { field = 'elapsed' } }, answering, request)

    t.assert_equals(request.elapsed, 0.5)
    t.assert_equals(request.duration, nil)
end

g.test_timing_gives_the_measurement_to_the_receiver = function()
    local observe, seen = helper.observer()
    local request = { path = '/customers' }

    through({ 'timing', { observe = observe } }, refusing, request)

    t.assert_equals(#seen, 1)
    t.assert_equals(seen[1][1], 0.5)
    t.assert_equals(seen[1][2], request)
    t.assert_equals(seen[1][3], 'хранилище молчит')
end

g.test_layer_above_measures_more_than_the_one_below = function()
    local request = {}

    g.middleware.chain({ 'log', 'timing' }):run(request, answering)

    t.assert_equals(request.duration, 0.5)
    t.assert_equals(g.logged('seconds=1.5'), true)
end

g.test_broken_receiver_of_the_measurement_does_not_cost_the_request = function()
    local observe = function()
        error('приёмник метрик молчит')
    end

    t.assert_equals(through({ 'timing', { observe = observe } }, answering), 'ответ')
    t.assert_equals(g.logged('отдать замер времени запроса не удалось'), true)
    t.assert_equals(g.logged('приёмник метрик молчит'), true)
end

g.test_receiver_of_the_measurement_is_a_function = function()
    assert_refused(
        'timing',
        { observe = 'метрики' },
        'приёмник замера — функция (seconds, context, err), а не string'
    )
end

g.test_handler_that_does_not_yield_still_takes_time = function()
    -- Часы настоящие. Обработчик, не уступивший управления, — разбор тела,
    -- ответ из кэша — по отметке цикла событий занимал бы ровно ноль,
    -- и медленный запрос выглядел бы в журнале и в метриках мгновенным.
    helper.part('tnt.middleware.layer.common')._set_source(nil)

    local request = {}

    through('timing', function()
        return #string.rep('ответ', 1e6)
    end, request)

    t.assert_gt(request.duration, 0)
end

g.test_timing_does_not_demand_a_table_for_a_context = function()
    t.assert_equals(through('timing', answering, 'просто строка'), 'ответ')
end

g.test_rescue_lets_a_good_answer_through_without_a_word = function()
    t.assert_equals(through('rescue', answering), 'ответ')
    t.assert_equals(g.logged('запрос сорвался'), false)
end

g.test_rescue_writes_about_a_refusal_once_and_keeps_it = function()
    local response, err = through('rescue', refusing)

    t.assert_equals(helper.refusal(response, err), 'хранилище молчит')
    t.assert_equals(g.logged('запрос сорвался'), true)
    t.assert_equals(g.logged('ERROR'), true)
end

g.test_a_broken_description_costs_the_rescue_its_record_but_not_the_refusal = function()
    local describe = function()
        error('описатель сорвался')
    end

    local response, err = through({ 'rescue', { describe = describe } }, refusing)

    -- Без описания запись не собрать, но об этом сказано вслух, а отказ
    -- уходит дальше нетронутым.
    t.assert_equals(helper.refusal(response, err), 'хранилище молчит')
    t.assert_equals(g.logged('записать об отказе не удалось'), true)
    t.assert_equals(g.logged('описатель сорвался'), true)
    t.assert_equals(g.logged('запрос сорвался'), false)
end

g.test_rescue_turns_a_refusal_into_the_answer_of_the_application = function()
    local respond = function(context, err)
        return { status = 500, body = err, path = context.path }
    end

    local response, err = through({ 'rescue', { respond = respond } }, refusing, { path = '/customers' })

    t.assert_equals(err, nil)
    t.assert_equals(response, { status = 500, body = 'хранилище молчит', path = '/customers' })
end

g.test_answerer_that_answered_with_nothing_does_not_quench_the_refusal = function()
    local response, err = through({ 'rescue', { respond = function() end } }, refusing)

    t.assert_equals(helper.refusal(response, err), 'хранилище молчит')
end

g.test_answerer_of_the_rescue_is_a_function = function()
    assert_refused(
        'rescue',
        { respond = {} },
        'ответчик — функция (context, err) -> ответ, а не table'
    )
end

g.test_rescue_catches_the_fall_of_the_layers_below_it = function()
    local respond = function()
        return { status = 500 }
    end
    local thrown_at

    local response, err = through({ 'rescue', { respond = respond } }, function()
        thrown_at = assert(debug.getinfo(1, 'l')).currentline + 1
        error('обработчик сорвался')
    end)

    t.assert_equals(err, nil)
    t.assert_equals(response, { status = 500 })
    t.assert_equals(g.logged('обработчик сорвался'), true)

    -- Запись о поломке несёт стек места броска отдельным полем, а слово
    -- отказа — прежней строкой, без стека.
    local fields = g.records()[1].record.fields

    t.assert_str_contains(fields.traceback, ('layer_test.lua:%d: in function'):format(thrown_at))
    t.assert_not_str_contains(fields.err, 'stack traceback')
end

g.test_rescue_does_not_copy_the_stack_of_a_refusal_that_is_not_a_fall = function()
    -- О поломке со своим стеком уже написал тот, кто её завёл: вторая
    -- копия стека в журнале — вдвое больше строк без нового смысла.
    through(
        'rescue',
        refusing_with({ message = 'хранилище молчит', traceback = 'стек соседа' })
    )

    local fields = g.records()[1].record.fields

    t.assert_equals(fields.traceback, nil)
    t.assert_equals(fields.err, { message = 'хранилище молчит', traceback = 'стек соседа' })
end

g.test_verdict_of_the_layer_names_the_level_by_the_refusal_itself = function()
    -- Приговор проверяется и напрямую, а не только через запись: слой
    -- пишет неизвестный уровень как поломку, и оттого приговор, забывший
    -- ответить вовсе, выглядел бы в журнале ровно как верный.
    local rescue = helper.part('tnt.middleware.layer.rescue')

    t.assert_equals(rescue.level_of('хранилище молчит'), 'error')
    t.assert_equals(rescue.level_of({ reason = 'нет места на диске' }), 'error')
    t.assert_equals(rescue.level_of({ status = 500 }), 'error')
    t.assert_equals(rescue.level_of({ expected = false, status = 404 }), 'error')
    t.assert_equals(rescue.level_of({ status = 499 }), 'warn')
    t.assert_equals(rescue.level_of({ expected = true }), 'warn')

    t.assert_equals(rescue.EXPECTED_LEVEL, 'warn')
    t.assert_equals(rescue.BREAKDOWN_LEVEL, 'error')
end

--- Отказ упавшего шага: обработчик бросил названное.
---@param raised any Что бросил обработчик
---@return TntMiddlewareFall
local function thrown(raised)
    local response, err = g.middleware.chain({}):run({}, function()
        error(raised)
    end)

    helper.fallen(response, err)

    return err
end

g.test_verdict_judges_the_fall_by_what_was_thrown = function()
    -- Своих признаков у отказа упавшего шага нет: ожидаемый он или
    -- поломка, говорит брошенное, и судится оно теми же правилами, что
    -- и отказ, возвращённый парой.
    local rescue = helper.part('tnt.middleware.layer.rescue')

    t.assert_equals(rescue.level_of(thrown({ expected = true })), 'warn')
    t.assert_equals(rescue.level_of(thrown({ status = 404 })), 'warn')
    t.assert_equals(rescue.level_of(thrown({ status = 500 })), 'error')
    t.assert_equals(rescue.level_of(thrown('хранилище молчит')), 'error')
end

g.test_expected_refusal_thrown_below_is_a_warning_too = function()
    -- «Нет такого клиента» — работа узла, как его ни отдай: брошенный,
    -- он не должен попадаться дежурному среди записей о поломках.
    local response, err = through('rescue', function()
        error({ status = 404, message = 'нет такого клиента' })
    end)

    t.assert_equals(helper.fallen(response, err), 'обработчик упал: нет такого клиента')
    t.assert_equals(g.logged('запрос отклонён'), true)
    t.assert_equals(g.logged('WARN'), true)
    t.assert_equals(g.logged('запрос сорвался'), false)
    t.assert_equals(g.logged('ERROR'), false)
    -- Пишется он и без стека, как отказ парой: поломки за ним нет.
    t.assert_equals(g.records()[1].record.fields.traceback, nil)
    t.assert_equals(g.logged('stack traceback'), false)
end

g.test_expected_refusal_is_a_warning_and_not_an_error = function()
    local response, err = through('rescue', refusing_with({ status = 403 }))

    t.assert_equals(helper.refusal(response, err), { status = 403 })
    t.assert_equals(g.logged('запрос отклонён'), true)
    t.assert_equals(g.logged('WARN'), true)
    t.assert_equals(g.logged('запрос сорвался'), false)
    t.assert_equals(g.logged('ERROR'), false)
end

g.test_refusal_that_calls_itself_expected_is_taken_at_its_word = function()
    through('rescue', refusing_with({ expected = true }))

    t.assert_equals(g.logged('запрос отклонён'), true)
    t.assert_equals(g.logged('WARN'), true)
end

g.test_sign_of_the_refusal_outweighs_its_status = function()
    through('rescue', refusing_with({ expected = false, status = 404 }))

    t.assert_equals(g.logged('запрос сорвался'), true)
    t.assert_equals(g.logged('ERROR'), true)
end

g.test_refusal_of_the_server_itself_stays_an_error = function()
    through('rescue', refusing_with({ status = 500 }))

    t.assert_equals(g.logged('запрос сорвался'), true)
    t.assert_equals(g.logged('ERROR'), true)
end

g.test_last_status_before_the_server_ones_is_still_a_refusal = function()
    through('rescue', refusing_with({ status = 499 }))

    t.assert_equals(g.logged('запрос отклонён'), true)
    t.assert_equals(g.logged('WARN'), true)
end

g.test_refusal_without_any_sign_is_taken_for_a_breakdown = function()
    through('rescue', refusing_with({ reason = 'хранилище молчит' }))

    t.assert_equals(g.logged('запрос сорвался'), true)
    t.assert_equals(g.logged('ERROR'), true)
end

g.test_rescue_writes_at_the_level_the_application_named = function()
    local seen = {}

    local level_of = function(err)
        table.insert(seen, err)

        return 'debug'
    end

    through({ 'rescue', { level_of = level_of } }, refusing)

    t.assert_equals(seen, { 'хранилище молчит' })
    t.assert_equals(g.logged('DEBUG'), true)
    t.assert_equals(g.logged('запрос сорвался'), true)
end

g.test_verdict_may_call_expected_what_the_layer_would_not = function()
    through({
        'rescue',
        {
            level_of = function()
                return 'warn'
            end,
        },
    }, refusing)

    t.assert_equals(g.logged('запрос отклонён'), true)
    t.assert_equals(g.logged('WARN'), true)
end

g.test_level_unknown_to_the_journal_does_not_lower_the_record = function()
    through({
        'rescue',
        {
            level_of = function()
                return 'громко'
            end,
        },
    }, refusing_with({ status = 403 }))

    t.assert_equals(g.logged('запрос сорвался'), true)
    t.assert_equals(g.logged('ERROR'), true)
end

g.test_verdict_about_the_level_is_a_function = function()
    assert_refused(
        'rescue',
        { level_of = {} },
        'приговор об уровне — функция (err) -> уровень, а не table'
    )
end

g.test_broken_verdict_does_not_take_the_record_down_with_it = function()
    local level_of = function()
        error('приговор сорвался')
    end

    local response, err = through({ 'rescue', { level_of = level_of } }, refusing_with({ status = 403 }))

    t.assert_equals(helper.refusal(response, err), { status = 403 })

    -- Запись остаётся целиком — и словами, и полями: сорвись приговор
    -- вместе с ней, об отказе не осталось бы ни строки, а это ровно
    -- та тишина, ради которой приговор и заведён. Уровень при этом
    -- откатывается к поломке, а не к встроенному приговору: тот назвал
    -- бы этот отказ ожидаемым и спрятал бы его среди предупреждений.
    t.assert_equals(g.logged('запрос сорвался'), true)
    t.assert_equals(g.logged('ERROR'), true)
    t.assert_equals(g.logged('err={"status":403}'), true)
    t.assert_equals(g.logged('level_of='), true)
    t.assert_equals(g.logged('приговор сорвался'), true)

    -- И записи о неудавшейся записи при этом нет: ответил приговор
    -- или сорвался, об отказе журнал узнаёт одной строкой.
    t.assert_equals(g.logged('записать об отказе не удалось'), false)
    t.assert_equals(g.logged('запрос отклонён'), false)
    t.assert_equals(g.logged('WARN'), false)
end

g.test_verdict_that_answered_leaves_no_word_about_itself_in_the_record = function()
    through({
        'rescue',
        {
            level_of = function()
                return 'debug'
            end,
        },
    }, refusing)

    t.assert_equals(g.logged('DEBUG'), true)
    t.assert_equals(g.logged('level_of='), false)
end

g.test_request_id_gives_out_its_own_name_when_none_came = function()
    local request = {}

    t.assert_equals(through('request_id', answering, request), 'ответ')
    t.assert_equals(request.request_id, 'запрос-1')
end

g.test_request_id_puts_the_identifier_into_the_context_for_the_rest_of_the_chain = function()
    local context = helper.part('tnt.context')
    local seen = nil

    t.assert_equals(context.get('request_id'), nil)

    through('request_id', function()
        seen = context.all()

        return 'ответ'
    end, { request_id = 'чужой-7' })

    t.assert_equals(seen, { request_id = 'чужой-7' })
    t.assert_equals(context.get('request_id'), nil)
end

g.test_request_id_leaves_the_context_as_it_was_when_the_handler_throws = function()
    local context = helper.part('tnt.context')
    local response, err = through('request_id', function()
        error('обработчик упал')
    end)

    t.assert_str_contains(helper.fallen(response, err), 'обработчик упал')
    t.assert_equals(context.get('request_id'), nil)
end

g.test_request_id_replaces_an_identifier_that_fails_the_check_of_the_context = function()
    for index, given in ipairs({ ('x'):rep(129), 'с переводом\nстроки', '', {}, '\xff' }) do
        local request = { request_id = given }

        through('request_id', answering, request)

        t.assert_equals(request.request_id, ('запрос-%d'):format(index))
    end

    local taken = { headers = { ['x-request-id'] = ('x'):rep(129) } }

    through({
        'request_id',
        {
            take = function(request)
                return request.headers['x-request-id']
            end,
        },
    }, answering, taken)

    t.assert_equals(taken.request_id, 'запрос-6')

    -- Ровно предел — годится, как и число: правило одно на всех.
    local fitting = { request_id = ('x'):rep(128) }

    through('request_id', answering, fitting)

    t.assert_equals(fitting.request_id, ('x'):rep(128))

    local numbered = { request_id = 42 }

    through('request_id', answering, numbered)

    t.assert_equals(numbered.request_id, 42)
end

g.test_request_id_gives_out_a_ulid_unless_told_otherwise = function()
    helper.part('tnt.middleware.layer.common')._set_source(nil)

    local first = {}
    local second = {}

    through('request_id', answering, first)
    through('request_id', answering, second)

    t.assert_equals(helper.part('tnt.id').is_ulid(first.request_id), true)
    t.assert_equals(helper.part('tnt.id').is_ulid(second.request_id), true)
    t.assert_not_equals(first.request_id, second.request_id)
end

g.test_the_header_name_is_the_one_declared_at_the_context_key = function()
    t.assert_equals(g.middleware.REQUEST_HEADER, helper.part('tnt.context').REQUEST_ID_HEADER)
    t.assert_equals(g.middleware.REQUEST_HEADER, 'x-request-id')
end

g.test_request_id_keeps_the_one_that_came_with_the_request = function()
    local request = { request_id = 'чужой-7' }

    through('request_id', answering, request)

    t.assert_equals(request.request_id, 'чужой-7')
end

g.test_request_id_takes_the_one_that_came_from_where_it_was_told = function()
    local take = function(context)
        return context.headers['x-request-id']
    end

    local request = { headers = { ['x-request-id'] = 'из заголовка' } }

    through({ 'request_id', { take = take } }, answering, request)

    t.assert_equals(request.request_id, 'из заголовка')
end

g.test_request_id_does_not_ask_where_it_already_knows = function()
    local take = function()
        error('брать не надо было')
    end

    local request = { request_id = 'чужой-7' }

    through({ 'request_id', { take = take } }, answering, request)

    t.assert_equals(request.request_id, 'чужой-7')
end

g.test_request_id_lies_where_it_was_told_to = function()
    local request = {}

    through({ 'request_id', { field = 'trace' } }, answering, request)

    t.assert_equals(request.trace, 'запрос-1')
    t.assert_equals(request.request_id, nil)
end

g.test_request_id_is_given_out_by_what_the_caller_named = function()
    local request = {}

    through({ 'request_id', { generate = helper.counter('свой') } }, answering, request)

    t.assert_equals(request.request_id, 'свой-1')
end

g.test_source_of_the_identifier_that_came_is_a_function = function()
    assert_refused(
        'request_id',
        { take = 'из заголовка' },
        'откуда взять опознаватель — функция (context), а не string'
    )
end

g.test_issuing_of_the_identifiers_is_a_function = function()
    assert_refused(
        'request_id',
        { generate = {} },
        'выдача опознавателей — функция () -> имя, а не table'
    )
end

g.test_request_id_has_nowhere_to_lie_in_a_context_that_is_not_a_table = function()
    local response, err = through('request_id', answering, 'просто строка')

    t.assert_equals(
        helper.refusal(response, err),
        'опознаватель запроса некуда положить: контекст не таблица'
    )
end

--- Проводит запрос с готовым опознавателем через слой заголовка.
---@param options table|nil
---@param handler fun(context: any): any, any
---@return any response
---@return any err
local function echoed(options, handler)
    return through({ 'request_id_header', options }, handler, { request_id = 'запрос-7' })
end

g.test_request_id_goes_out_with_the_answer_as_a_header = function()
    local response = echoed(nil, responding)

    t.assert_equals(response, { status = 200, headers = { ['x-request-id'] = 'запрос-7' } })
end

g.test_header_with_the_identifier_keeps_the_headers_that_were_there = function()
    local response = echoed(nil, function()
        return { headers = { ['content-type'] = 'application/json' } }
    end)

    t.assert_equals(response.headers['content-type'], 'application/json')
    t.assert_equals(response.headers['x-request-id'], 'запрос-7')
end

g.test_identifier_of_the_conveyor_outweighs_the_one_the_handler_wrote = function()
    local response = echoed(nil, function()
        return { headers = { ['x-request-id'] = 'чужой-7' } }
    end)

    t.assert_equals(response.headers['x-request-id'], 'запрос-7')
end

g.test_header_with_the_identifier_is_named_the_way_the_caller_wants = function()
    local response = echoed({ header = 'x-trace' }, responding)

    t.assert_equals(response.headers['x-trace'], 'запрос-7')
    t.assert_equals(response.headers['x-request-id'], nil)
end

g.test_header_takes_the_identifier_from_the_field_it_was_told_about = function()
    local response = through({ 'request_id_header', { field = 'trace' } }, responding, { trace = 'свой-7' })

    t.assert_equals(response.headers['x-request-id'], 'свой-7')
end

g.test_answer_to_a_request_without_an_identifier_goes_out_as_it_is = function()
    t.assert_equals(through('request_id_header', responding), { status = 200 })
end

g.test_answer_that_is_not_a_table_has_nowhere_to_take_a_header = function()
    t.assert_equals(echoed(nil, answering), 'ответ')
end

g.test_context_that_is_not_a_table_carries_no_identifier_either = function()
    t.assert_equals(through('request_id_header', responding, 'просто строка'), { status = 200 })
end

g.test_refusal_from_below_gets_no_header_and_stays_a_refusal = function()
    local response, err = echoed(nil, refusing)

    t.assert_equals(helper.refusal(response, err), 'хранилище молчит')
end

g.test_identifier_goes_into_the_answer_where_the_caller_puts_it = function()
    local seen = {}

    local response = echoed({
        put = function(answer, id)
            seen.answer = answer
            seen.id = id
        end,
    }, responding)

    t.assert_equals(response, { status = 200 })
    t.assert_equals(seen.id, 'запрос-7')
    t.assert_equals(seen.answer, response)
end

g.test_broken_putter_does_not_cost_the_ready_answer = function()
    local response = echoed({
        put = function()
            error('укладчик сорвался')
        end,
    }, responding)

    -- Ответ к этому мигу собран, и номер в заголовке его не стоит.
    t.assert_equals(response, { status = 200 })
    t.assert_equals(g.logged('положить опознаватель в ответ не удалось'), true)
    t.assert_equals(g.logged('укладчик сорвался'), true)
end

g.test_answer_whose_headers_are_not_a_table_goes_out_all_the_same = function()
    -- Встроенный укладчик спотыкается о такой ответ сам, и это тот же
    -- случай: заголовок не написан, а ответ цел.
    local response = echoed(nil, function()
        return { status = 200, headers = 'заголовки строкой' }
    end)

    t.assert_equals(response, { status = 200, headers = 'заголовки строкой' })
    t.assert_equals(g.logged('положить опознаватель в ответ не удалось'), true)
end

g.test_putter_of_the_identifier_is_a_function = function()
    assert_refused(
        'request_id_header',
        { put = 'в заголовок' },
        'укладчик опознавателя — функция (response, id), а не string'
    )
end
