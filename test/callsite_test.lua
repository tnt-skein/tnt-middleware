--- Место записи слоёв конвейера в настоящем журнале ядра.
---
--- Журнал ядра берёт `file`/`line` из кадра, позвавшего журнал, и правдой
--- они остаются, только пока запись идёт из самого слоя или хвостовым
--- вызовом из общего кода. `pcall` вокруг записи перевёл бы место в `[C]:-1`,
--- а запись из середины общего кода — в `common.lua` для всех слоёв сразу.
--- Двойник журнала этого не видит, поэтому проверка идёт в дочернем
--- процессе с настоящим журналом, а ожидаемые строки ищутся в исходниках
--- слоёв — чтобы проверка не ломалась от каждой новой строки комментария.

local t = require('luatest')
local fio = require('fio')
local json = require('json')

local helper = dofile('test/helper.lua')

--- Цепочка из всех слоёв, у которых есть что записать, и три прохода:
--- удачный, с отказом и с сорвавшимся описателем.
local SCENARIO = [=[
require('log').cfg({ log = DIR .. '/journal.log', format = 'json', level = 'debug' })

local middleware = require('tnt.middleware')

local function describe(context)
    if context.broken then
        error('описатель сорвался')
    end

    return { path = '/customers/7' }
end

local chain = middleware.chain({
    { 'rescue', { describe = describe } },
    { 'log', { describe = describe } },
    { 'timing', { observe = function() error('приёмник упал') end } },
    { 'request_id_header', { put = function() error('укладчик сорвался') end } },
})

chain:run({ request_id = 'r-1' }, function()
    return { status = 200 }
end)
chain:run({ request_id = 'r-2' }, function()
    return nil, { status = 500 }
end)
chain:run({ request_id = 'r-3', broken = true }, function()
    return nil, { status = 500 }
end)
]=]

--- Какая запись из какой строки какого слоя должна прийти.
local EXPECTED = {
    { message = 'запрос прошёл', layer = 'log', fragment = "journal[level]('запрос прошёл'" },
    {
        message = 'запрос не прошёл',
        layer = 'log',
        fragment = "journal.warn('запрос не прошёл'",
    },
    {
        message = 'записать о запросе не удалось',
        layer = 'log',
        fragment = "common.failed(journal, 'записать о запросе'",
    },
    { message = 'запрос сорвался', layer = 'rescue', fragment = 'write(level == Module.EXPECTED_LEVEL' },
    {
        message = 'записать об отказе не удалось',
        layer = 'rescue',
        fragment = "common.failed(journal, 'записать об отказе'",
    },
    {
        message = 'отдать замер времени запроса не удалось',
        layer = 'timing',
        fragment = "common.aside(journal, 'отдать замер времени запроса'",
    },
    {
        message = 'положить опознаватель в ответ не удалось',
        layer = 'request_id_header',
        fragment = "common.aside(journal, 'положить опознаватель в ответ'",
    },
}

local g = t.group('tnt.middleware.callsite')

g.before_all(function()
    g.dir = helper.run_script(SCENARIO)
end)

g.after_all(function()
    if g.dir ~= nil then
        fio.rmtree(g.dir)
    end
end)

--- Номер первой строки исходника, в которой есть кусок текста.
---@param path string
---@param fragment string
---@return integer
local function line_of(path, fragment)
    local number = 0

    for line in helper.read_file(path):gmatch('([^\n]*)\n') do
        number = number + 1

        if line:find(fragment, 1, true) ~= nil then
            return number
        end
    end

    error(('в %s нет строки с «%s»'):format(path, fragment))
end

g.test_every_layer_record_points_at_the_line_of_its_layer = function()
    local records = {}

    for line in helper.read_file(fio.pathjoin(g.dir, 'journal.log')):gmatch('([^\n]*)\n') do
        local record = json.decode(line)

        if record.module == 'tnt.middleware' then
            records[record.message] = records[record.message] or {}
            table.insert(records[record.message], record)
        end
    end

    for _, expected in ipairs(EXPECTED) do
        local suffix = ('tnt/middleware/layer/%s.lua'):format(expected.layer)
        local line = line_of(helper.path_of('tnt.middleware.layer.' .. expected.layer), expected.fragment)
        local found = records[expected.message] or {}

        t.assert_not_equals(#found, 0, expected.message)

        for _, record in ipairs(found) do
            t.assert_equals(record.file:sub(-#suffix), suffix, expected.message)
            t.assert_equals(record.line, line, expected.message)
        end
    end
end
