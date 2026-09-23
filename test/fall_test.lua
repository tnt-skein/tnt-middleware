--- Проверки отказа упавшего шага: слово, стек, брошенное и признание.

local t = require('luatest')

local helper = dofile('test/helper.lua')

--- Ошибки Tarantool: брошенный их объект отдаёт отказу свой текст.
--- Конструктор в аннотациях описан не полностью, поэтому берётся через
--- промежуточную ссылку.
---@type any
local box_error = box.error

local g = helper.group('tnt.middleware.fall')

--- Модуль отказа упавшего шага.
---@return table
local function fall()
    return helper.part('tnt.middleware.fall')
end

--- Отказ, который ловушка шага собрала из брошенного.
---@param what string Как назван шаг
---@param raised any Что бросили
---@return TntMiddlewareFall
local function trapped(what, raised)
    local ok, err = xpcall(function()
        error(raised, 0)
    end, fall().trap(what))

    t.assert_equals(ok, false)

    return err
end

g.test_the_fall_is_printed_by_its_word_and_carries_the_stack_apart = function()
    local err = trapped('слой «audit» упал', 'хранилище молчит')

    t.assert_equals(err.message, 'слой «audit» упал: хранилище молчит')
    -- Печать — только слово: журнал и всякий, кто печатает отказ, видят
    -- прежнюю строку, а стек лежит полем и в неё не входит.
    t.assert_equals(tostring(err), 'слой «audit» упал: хранилище молчит')
    -- Стек начинается с места броска: ловушки, которая его сняла, в нём нет.
    t.assert_equals(err.traceback:find("\nstack traceback:\n\t[C]: in function 'error'\n\t", 1, true), 1)
    t.assert_str_contains(err.traceback, 'fall_test.lua:')
end

g.test_a_thrown_table_gives_the_fall_its_message = function()
    t.assert_equals(
        trapped('обработчик упал', { message = 'нет места на диске', code = 7 }).message,
        'обработчик упал: нет места на диске'
    )
    t.assert_equals(
        trapped(
            'обработчик упал',
            box_error.new({ code = box_error.PROC_LUA, reason = 'спейс занят' })
        ).message,
        'обработчик упал: спейс занят'
    )
    t.assert_str_contains(
        trapped('обработчик упал', { code = 7 }).message,
        'обработчик упал: table: '
    )
end

g.test_the_fall_is_told_by_its_metatable_and_not_by_its_fields = function()
    local err = trapped('обработчик упал', 'беда')

    t.assert_equals(fall().is(err), true)
    -- Те же поля бывают и у чужого отказа, и чей он, по полям не сказать.
    t.assert_equals(fall().is({ message = err.message, traceback = err.traceback }), false)
    t.assert_equals(fall().is(err.message), false)
    t.assert_equals(fall().is(nil), false)
end

g.test_the_fall_keeps_what_was_thrown_as_it_is = function()
    -- Брошенное нарочно отказом — «нет такого клиента» со статусом —
    -- в слове упавшего шага теряет статус и код; тот, кто превращает
    -- отказ в ответ, берёт его отсюда целиком.
    local refusal = { status = 404, message = 'нет такого клиента' }
    local fault = box_error.new({ code = box_error.PROC_LUA, reason = 'спейс занят' })

    t.assert_is(trapped('обработчик упал', refusal).raised, refusal)
    t.assert_is(trapped('обработчик упал', fault).raised, fault)
    t.assert_equals(
        trapped('обработчик упал', 'хранилище молчит').raised,
        'хранилище молчит'
    )
end

g.test_a_fall_thrown_again_passes_on_what_was_thrown_first = function()
    -- Слой получил отказ упавшего шага от `next` и бросил его заново:
    -- бросили дальше то же самое, и отказ обработчика обязан дойти своим
    -- до того, кто превращает его в ответ. Слово и стек у нового свои.
    local refusal = { status = 404, message = 'нет такого клиента' }
    local first = trapped('обработчик упал', refusal)
    local again = trapped('слой «audit» упал', first)

    t.assert_is(again.raised, refusal)
    t.assert_equals(
        again.message,
        'слой «audit» упал: обработчик упал: нет такого клиента'
    )
    t.assert_equals(fall().is(again), true)
end
