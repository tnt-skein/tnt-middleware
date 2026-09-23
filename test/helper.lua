--- Общие средства тестов пакета конвейера.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.clock`, `tnt.context`, `tnt.id`, `tnt.log`, `tnt.must`,
--- `tnt.external` — берутся из `.rocks` обычным `require`: проверяется
--- этот пакет, а не они. Ребёнок-процесс берёт их так же. Ловушка журнала
--- встаёт и на установленный `tnt.log` — тот же экземпляр, которым пишут
--- слои.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы, которые идут
--- сами, счётчик и приёмник, ловушка журнала, ребёнок-процесс и файлы —
--- грузится так же и один раз на процесс: второй экземпляр загрузчика
--- не знал бы, что вытеснил первый, и не вернул бы вытесненное на место.
---
--- Проверки конвейера берут всё через помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.factory', path = 'test/testing/factory.lua' },
    { name = 'tnt.testing.child', path = 'test/testing/child.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    clock = package.loaded['tnt.testing.clock'].new,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    sequence = package.loaded['tnt.testing.factory'].sequence,
    recorder = package.loaded['tnt.testing.factory'].recorder,
    run_script = package.loaded['tnt.testing.child'].run,
    read_file = package.loaded['tnt.testing.files'].read,
}

local helper = {}

--- Шаг часов: на столько они уходят вперёд от каждого чтения.
---
--- Половина секунды, а не миллисекунда: длительность попадает в журнал
--- и в приёмник замера, и число вроде 0.5 в отказавшей проверке читается
--- глазом, а 0.001 приходится разглядывать.
local STEP = 0.5

--- Модули пакета в порядке зависимостей.
helper.MODULES = {
    { name = 'tnt.middleware.fall', path = 'tnt/middleware/fall.lua' },
    { name = 'tnt.middleware.blame', path = 'tnt/middleware/blame.lua' },
    { name = 'tnt.middleware.chain', path = 'tnt/middleware/chain.lua' },
    { name = 'tnt.middleware.filter', path = 'tnt/middleware/filter.lua' },
    { name = 'tnt.middleware.layer.common', path = 'tnt/middleware/layer/common.lua' },
    { name = 'tnt.middleware.layer.cors', path = 'tnt/middleware/layer/cors.lua' },
    { name = 'tnt.middleware.layer.log', path = 'tnt/middleware/layer/log.lua' },
    { name = 'tnt.middleware.layer.timing', path = 'tnt/middleware/layer/timing.lua' },
    { name = 'tnt.middleware.layer.rescue', path = 'tnt/middleware/layer/rescue.lua' },
    { name = 'tnt.middleware.layer.request_id', path = 'tnt/middleware/layer/request_id.lua' },
    { name = 'tnt.middleware.layer.request_id_header', path = 'tnt/middleware/layer/request_id_header.lua' },
    { name = 'tnt.middleware.registry', path = 'tnt/middleware/registry.lua' },
    { name = 'tnt.middleware', path = 'tnt/middleware.lua' },
}

--- Уже загруженный модуль пакета: проверкам слоёв нужны их соседи.
helper.part = testing.module

--- Путь к исходнику модуля пакета по его имени.
---
--- Проверка места записи ищет строки в самих исходниках слоёв, а путь
--- к ним у пакета в дереве и у отдельного пакета разный.
---@param name string Имя модуля: tnt.middleware.layer.log
---@return string
function helper.path_of(name)
    for _, module in ipairs(helper.MODULES) do
        if module.name == name then
            return module.path
        end
    end

    error(('в пакете нет модуля %s'):format(name))
end

--- Выполняет сценарий отдельным процессом Tarantool с исходниками пакета
--- и отдаёт его каталог; каталог сценария — переменная `DIR`.
---
--- Настоящий журнал ядра настраивается только в своём процессе: в процессе
--- проверок его уже настроил luatest.
---@param body string
---@return string dir
function helper.run_script(body)
    return testing.run_script(helper.MODULES, body)
end

--- Содержимое файла целиком.
---@param path string
---@return string
function helper.read_file(path)
    return testing.read_file(path)
end

--- Выдача опознавателей по порядку: `приставка-1`, `приставка-2`.
helper.counter = testing.sequence

--- Приёмник, запоминающий аргументы каждого вызова списком.
helper.observer = testing.recorder

--- Заводит группу проверок с заново загруженными исходниками.
---
--- Исходники грузятся перед каждой проверкой: и общий реестр фасада,
--- и подменённые средства живут в модулях, и не загруженный заново пакет
--- принёс бы в следующую проверку настройки от предыдущей.
---@param name string Имя группы
---@return table group Поля middleware, clock, logged и records готовы к проверке
function helper.group(name)
    local group = t.group(name)
    local journal = testing.capture_log()

    group.before_each(function()
        journal.forget()

        group.middleware = testing.load_sources(helper.MODULES, 'tnt.middleware')
        group.logged = journal.logged
        group.records = journal.records

        -- Часы идут сами: каждое чтение двигает их на шаг вперёд, поэтому
        -- длительность любого прохода — точное число, а не «сколько успела
        -- машина». Настоящие часы дали бы то ноль, то микросекунду.
        group.clock = testing.clock({ step = STEP })

        helper.part('tnt.middleware.layer.common')._set_source({
            monotonic = group.clock.monotonic,
            identifier = helper.counter('запрос'),
        })
    end)

    group.after_each(function()
        testing.unload_sources(helper.MODULES)
    end)

    return group
end

--- Слои, которые отмечаются в общем следе до и после `next`.
---
--- След — единственный способ увидеть порядок: сам по себе слой ничего
--- не возвращает, а важно, когда он сработал относительно соседей.
---@return string[] trail Отметки по порядку
---@return fun(name: string): TntMiddlewareFn marking Слой, который отмечается
function helper.trail()
    local trail = {}

    return trail,
        function(name)
            return function(context, next_layer)
                table.insert(trail, name .. ' до')

                local response, err = next_layer(context)

                table.insert(trail, name .. ' после')

                return response, err
            end
        end
end

--- Обработчик, который отмечается в следе и отвечает одним и тем же.
---@param trail string[]
---@param answer any
---@return fun(context: any): any
function helper.handler(trail, answer)
    return function(_)
        table.insert(trail, 'обработчик')

        return answer
    end
end

--- Отказ, который дала цепочка; ответ в этом случае — ошибка проверки.
---@param response any
---@param err any
---@return any
function helper.refusal(response, err)
    t.assert_equals(response, nil)

    return (assert(err, 'цепочка не отказала'))
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не строку пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`, и не хвостом: у хвостового вызова кадра замыкания
--- нет, и вина ушла бы к тому, кто его позвал. Место сверяется целиком —
--- файлом, строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local ok, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(ok, false, case[2])
        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Слово отказа упавшего шага; иной отказ — ошибка проверки.
---
--- Слово берётся печатью, а не полем: так отказ видят журнал и всякий,
--- кто его печатает, и проверка идёт тем же путём. Стек сверяется здесь
--- же, на вид: отказ падения без стека — ровно то, от чего он заведён.
---@param response any
---@param err any
---@return string
function helper.fallen(response, err)
    local refusal = helper.refusal(response, err)

    t.assert_equals(helper.part('tnt.middleware.fall').is(refusal), true, 'отказ не упавшего шага')
    t.assert_str_contains(refusal.traceback, 'stack traceback:')

    return tostring(refusal)
end

return helper
