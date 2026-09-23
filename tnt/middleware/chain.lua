--- Цепочка слоёв: порядок прохода, вызов и правка состава на месте.
---
--- Слой — функция `(context, next)`. Всё, что он делает до `next`,
--- случается на входе; всё, что после, — на выходе; а не позвав `next`,
--- слой отвечает сам, не пустив запрос дальше. Отсюда и порядок: на входе
--- слои идут сверху вниз, на выходе — снизу вверх.
---
---     цепочка { A, B }, обработчик H
---
---     A до next → B до next → H → B после next → A после next
---
--- Пара хуков «до» и «после» дала бы тот же порядок, но не дала бы
--- главного: между ними нельзя завести свою переменную, нельзя обернуть
--- вызов в pcall, нельзя не позвать обработчик вовсе и нельзя позвать его
--- дважды — а из последнего и состоит повтор. Слой-обёртка умеет всё
--- четыре, и ценой одному: он обязан вернуть то, что вернул `next`.
---
--- Цепочка не знает, что такое запрос и что такое ответ. Контекст для неё
--- — непрозрачное значение, которое она несёт от слоя к слою; ответ —
--- то, что вернул обработчик или слой вместо него. Поэтому один и тот же
--- механизм годится и входящему запросу, и исходящему.
---
--- Обёрнутый обработчик собирается один раз на состав слоёв: замыкания
--- и имена слоёв не строятся заново на каждый запрос. Но цепочку правят
--- и после обёртывания — на этом держится `without` у чужой готовой
--- цепочки, — поэтому у состава есть отметка, и обёртка сверяет её перед
--- каждым проходом. Цена обещания — одно сравнение, а не сборка.
---
--- Слой с фильтром (`layer.only`, см. `tnt.middleware.filter`) стоит
--- в цепочке как все, но зовётся только на запрос, прошедший фильтр;
--- остальные идут мимо него прямо в остаток, и на выходе он их не видит.
---
--- Исход у цепочки всегда пара «ответ, отказ», и пустой она не бывает:
--- либо ответ, либо причина, по которой ответа нет. Брошенное исключение
--- к этой паре приводится — каждый шаг зовётся под xpcall, и упавший слой
--- становится отказом, который видят слои выше. Так падение третьего слоя
--- не отменяет ни записи в журнал, ни замера времени, сделанных первыми
--- двумя: их выход всё равно случится. Отказ упавшего шага несёт стек
--- места броска (`tnt.middleware.fall`): перехват его разматывает, и снять
--- стек можно только в ловушке, пока он ещё есть.
---
--- Бросает цепочка только на ошибке объявления, и место в таком отказе —
--- строка того, кто позвал метод цепочки (`tnt.middleware.blame`). Поэтому
--- работа методов живёт в местных функциях, бросающих без места, а методы
--- зовут их через `blame.call` и друг друга не зовут.

local fail = require('tnt.must.fail')

local blame = require('tnt.middleware.blame')
local fall = require('tnt.middleware.fall')

local Module = {}

---@alias TntMiddlewareNext fun(context?: any): any, any
---@alias TntMiddlewareFn fun(context: any, next_layer: TntMiddlewareNext): any, any

---@class TntMiddlewareLayer
---@field name string|nil Имя слоя в цепочке
---@field fn TntMiddlewareFn Сам слой
---@field only TntMiddlewareOnly|nil Фильтр: слой зовётся только на запрос, прошедший его

---@class TntMiddlewareChain
---@field registry TntMiddleware Реестр, из которого берутся объявленные слои
---@field layers TntMiddlewareLayer[] Слои по порядку прохода
---@field stamp table Отметка нынешнего состава слоёв
local Chain = {}
Chain.__index = Chain

--- Отмечает, что состав слоёв изменился.
---
--- Отметка — новая таблица, а не счётчик правок: считать здесь нечего,
--- вопрос ровно один — тот ли это состав, что был при сборке прохода.
--- Равенство таблиц отвечает на него прямо, а число отвечало бы через
--- величину, которую рано или поздно кто-нибудь прочтёт как количество
--- правок и станет на неё полагаться.
---@param chain TntMiddlewareChain
local function restamp(chain)
    chain.stamp = {}
end

--- Что сказать про слой, который ничего не вернул.
---
--- Два случая, и путать их нельзя: не позвавший `next` потерял запрос,
--- а позвавший — потерял ответ. Починка у них разная, поэтому и текст
--- разный.
local SKIPPED =
    'не позвал next и не вернул ответа: запрос дальше не пошёл, а отвечать нечем'
local LOST =
    'позвал next, но не вернул ответ: остаток цепочки отработал впустую'

--- Как назвать слой в тексте отказа.
---
--- Безымянный слой называется местом в цепочке: сказать «слой упал»
--- и не сказать какой — значит заставить читающего журнал перебирать
--- их все.
---@param layer TntMiddlewareLayer
---@param index integer
---@return string
local function label_of(layer, index)
    if layer.name ~= nil then
        return ('слой «%s»'):format(layer.name)
    end

    return ('слой №%d'):format(index)
end

--- Приводит брошенное к отказу.
---
--- Берёт не дело, а его исход: `guarded(xpcall(шаг, ловушка, аргументы))`.
--- Так шаг зовётся самим `xpcall`, без замыкания-обёртки вокруг него, —
--- а замыкание это строилось бы на каждый слой на каждом запросе. Отказ
--- собирает ловушка: после возврата из `xpcall` стек уже размотан.
---@param ok boolean Удался ли вызов
---@param response any Ответ шага либо отказ из ловушки
---@param err any
---@return any response
---@return any err
local function guarded(ok, response, err)
    if ok then
        return response, err
    end

    return nil, response
end

--- Что сказано о пустом ответе обработчика и чем ловится его падение.
local HANDLER_EMPTY = 'обработчик не вернул ни ответа, ни причины отказа'
local HANDLER_TRAP = fall.trap('обработчик упал')

--- Обработчик, укрытый от исключения и от пустого ответа.
---@param handler fun(context: any): any, any
---@return fun(context: any): any, any
local function bottom_of(handler)
    return function(context)
        local response, err = guarded(xpcall(handler, HANDLER_TRAP, context))

        -- Пустота от обработчика — не ответ и не отказ, а вызывающему
        -- надо что-то сказать. Сказать правду дешевле, чем заставить его
        -- разбираться, почему в ответе nil.
        if response == nil and err == nil then
            return nil, HANDLER_EMPTY
        end

        return response, err
    end
end

--- Оборачивает остаток прохода одним слоем.
---@param layer TntMiddlewareLayer
---@param index integer Место слоя в цепочке: им зовётся безымянный
---@param rest fun(context: any): any, any Остаток прохода
---@return fun(context: any): any, any
local function around(layer, index, rest)
    -- Тексты отказов и ловушка собираются при сборке прохода, а не при
    -- отказе: имя слоя от запроса к запросу не меняется, а format
    -- и замыкание на слой на запрос — это и есть та плата, которую потом
    -- ищут профилем.
    local label = label_of(layer, index)
    local trap = fall.trap(('%s упал'):format(label))
    local skipped = ('%s %s'):format(label, SKIPPED)
    local lost = ('%s %s'):format(label, LOST)
    local fn = layer.fn

    local pass = function(context)
        local called = false

        --- Остаток цепочки. Без аргумента идёт прежний контекст, с аргументом —
        --- новый: слою бывает нужно отдать вниз изменённый запрос, не трогая
        --- тот, который увидят на выходе слои выше.
        ---
        --- Звать остаток можно и не один раз: так устроен повтор — слой
        --- ведёт запрос по цепочке заново, пока не получит ответ. Цепочка
        --- запоминает лишь то, звали ли остаток вообще: этим «забыл позвать
        --- next» отличается от «позвал, но потерял ответ».
        ---@param replacement any
        ---@return any response
        ---@return any err
        local function forward(replacement)
            called = true

            if replacement == nil then
                replacement = context
            end

            return rest(replacement)
        end

        local response, err = guarded(xpcall(fn, trap, context, forward))

        -- Слой, не вернувший ничего, — самая частая ошибка в конвейерах:
        -- запрос тихо пропадает, а вызывающий получает пустоту без причины.
        -- Пустота с причиной лучше: она называет виновного и его промах.
        if response == nil and err == nil then
            return nil, called and lost or skipped
        end

        return response, err
    end

    local only = layer.only

    if only == nil then
        return pass
    end

    -- Запрос мимо фильтра идёт сразу в остаток, как будто слоя в цепочке
    -- нет: тот не зовётся ни на входе, ни на выходе. Проверка стоит
    -- только у слоёв с фильтром — остальным она не стоит ни сравнения.
    return function(context)
        if only(context) then
            return pass(context)
        end

        return rest(context)
    end
end

--- Собирает проход: обработчик, укрытый слоями.
---
--- Слои навешиваются с конца, потому что каждый оборачивает уже готовый
--- остаток: первый в списке оказывается снаружи — входит раньше всех
--- и выходит позже всех.
---@param layers TntMiddlewareLayer[]
---@param handler fun(context: any): any, any
---@return fun(context: any): any, any
local function compose(layers, handler)
    local pass = bottom_of(handler)

    for index = #layers, 1, -1 do
        pass = around(layers[index], index, pass)
    end

    return pass
end

--- Приводит аргумент к списку записей.
---
--- Список — обычный случай; одиночное имя допускается ради `chain('web')`,
--- где список из одного имени только мешает читать. Слой с параметрами
--- при этом остаётся вложенным списком — `{ { 'log', { ... } } }`:
--- иначе `{ 'log', { ... } }` читалось бы и как слой с параметрами,
--- и как два слоя подряд, а угадывать тут нечего.
---@param entries any
---@return any[]
local function entries_of(entries)
    if entries == nil then
        return {}
    end

    if type(entries) == 'table' then
        return entries
    end

    return { entries }
end

--- Заводит пустую цепочку с этим реестром.
---@param registry TntMiddleware
---@return TntMiddlewareChain
local function empty(registry)
    ---@type TntMiddlewareChain
    return setmetatable({ registry = registry, layers = {}, stamp = {} }, Chain)
end

--- Место названного слоя в цепочке, без места в отказе.
---
--- Имени, которого в цепочке нет, здесь быть не может: молча ничего
--- не сделать — худший исход. Приложение, убравшее чужую проверку входа
--- с опечаткой в имени, решило бы, что убрало её, и открыло бы наружу
--- то, что собиралось закрыть.
---@param chain TntMiddlewareChain
---@param name any
---@return integer
local function index_of(chain, name)
    ---@type integer|nil
    local found = nil

    for index, layer in ipairs(chain.layers) do
        if layer.name == name then
            found = index

            break
        end
    end

    if found == nil then
        fail.raise(
            ('в цепочке нет слоя «%s»; есть: %s'):format(
                tostring(name),
                table.concat(chain:names(), ', ')
            )
        )
    end

    return found
end

--- Проверяет, что имя в цепочке свободно.
---
--- Два слоя с одним именем сделали бы before, after и without
--- двусмысленными: непонятно, к которому из них относится правка.
---@param chain TntMiddlewareChain
---@param name string|nil
local function vacant(chain, name)
    if name == nil then
        return
    end

    for _, present in ipairs(chain.layers) do
        if present.name == name then
            fail.raise(('слой «%s» в цепочке уже есть'):format(name))
        end
    end
end

--- Ставит запись на указанное место, без места в отказе.
---@param chain TntMiddlewareChain
---@param at integer
---@param entry any
local function insert(chain, at, entry)
    -- Отметка меняется до правки, а не после: разбор записи или занятое
    -- имя бросают исключение посреди группы, и часть слоёв к этому мигу
    -- уже встала. Состав после такого броска — тоже новый состав.
    restamp(chain)

    for offset, layer in ipairs(chain.registry:resolve(entry)) do
        vacant(chain, layer.name)
        table.insert(chain.layers, at + offset - 1, layer)
    end
end

--- Что сказать тому, кто передал `use` второй аргумент.
local FILTER_ARGUMENT =
    "фильтр слоя пишется в самой записи: { слой, path = '/api', method = 'GET' }"

--- Добавляет запись в конец цепочки, без места в отказе.
---@param chain TntMiddlewareChain
---@param extra integer Сколько аргументов пришло после записи
---@param entry any
local function append(chain, extra, entry)
    if extra > 0 then
        fail.raise(FILTER_ARGUMENT)
    end

    insert(chain, #chain.layers + 1, entry)
end

--- Ставит запись рядом с названным слоем, без места в отказе.
---@param chain TntMiddlewareChain
---@param name any
---@param shift integer 0 — перед слоем, 1 — после него
---@param entry any
local function beside(chain, name, shift, entry)
    insert(chain, index_of(chain, name) + shift, entry)
end

--- Убирает названный слой, без места в отказе.
---@param chain TntMiddlewareChain
---@param name any
local function remove(chain, name)
    local at = index_of(chain, name)

    restamp(chain)
    table.remove(chain.layers, at)
end

--- Собирает цепочку из записей.
---
--- Зовёт её вход реестра (`chain` у реестра и у фасада), и отказ здесь
--- без места: место приписывает он.
---@param registry TntMiddleware
---@param entries any Список записей, одно имя или nil
---@return TntMiddlewareChain
function Module.new(registry, entries)
    local chain = empty(registry)

    for _, entry in ipairs(entries_of(entries)) do
        insert(chain, #chain.layers + 1, entry)
    end

    return chain
end

--- Имена слоёв по порядку прохода; безымянные — номером места.
---@return string[]
function Chain:names()
    local names = {}

    for index, layer in ipairs(self.layers) do
        table.insert(names, layer.name or ('№%d'):format(index))
    end

    return names
end

--- Место названного слоя в цепочке.
---@param name string
---@return integer
function Chain:index_of(name)
    local at = blame.call(index_of, self, name)

    return at
end

--- Ставит запись на указанное место. Группа разворачивается целиком.
---@param at integer
---@param entry any
---@return TntMiddlewareChain
function Chain:insert(at, entry)
    blame.call(insert, self, at, entry)

    return self
end

--- Добавляет запись в конец цепочки.
---
--- Второго аргумента нет нарочно. У рока http фильтр слоя — второй аргумент,
--- `use(handler, { path = … })`, и привычка к нему приходит вместе
--- с людьми; но отбросить его молча нельзя: слой, задуманный под `/api`,
--- встал бы на всё, и заметили бы это не скоро.
---@param entry any
---@return TntMiddlewareChain
function Chain:use(entry, ...)
    blame.call(append, self, select('#', ...), entry)

    return self
end

--- Ставит запись перед названным слоем: она сработает на входе раньше него.
---@param name string
---@param entry any
---@return TntMiddlewareChain
function Chain:before(name, entry)
    blame.call(beside, self, name, 0, entry)

    return self
end

--- Ставит запись после названного слоя: она сработает на входе позже него.
---@param name string
---@param entry any
---@return TntMiddlewareChain
function Chain:after(name, entry)
    blame.call(beside, self, name, 1, entry)

    return self
end

--- Убирает названный слой.
---@param name string
---@return TntMiddlewareChain
function Chain:without(name)
    blame.call(remove, self, name)

    return self
end

--- Отдельная цепочка с теми же слоями.
---
--- Правка общей цепочки в одном месте иначе меняла бы её всюду: маршрут,
--- которому не нужна проверка входа, снял бы её и у остальных.
---@return TntMiddlewareChain
function Chain:clone()
    local copy = empty(self.registry)

    for index, layer in ipairs(self.layers) do
        copy.layers[index] = layer
    end

    return copy
end

--- Обработчик, укрытый цепочкой, без места в отказе.
---@param chain TntMiddlewareChain
---@param handler any
---@return fun(context: any): any, any
local function wrapped(chain, handler)
    if type(handler) ~= 'function' then
        fail.raise('цепочке нужен обработчик: функция (context) -> ответ, отказ')
    end

    -- Проход собирается один раз на состав слоёв, а не на запрос.
    -- Сборка стоит замыкания на слой и имени слоя строкой на слой:
    -- на цепочке из пяти слоёв это втрое дороже самого прохода, и
    -- платилось бы на каждом запросе за состав, который после объявления
    -- маршрута уже не меняется.
    local built_from = chain.stamp
    local pass = compose(chain.layers, handler)

    return function(context)
        -- А когда состав всё же меняется, обёртка обязана идти по новому:
        -- правка цепочки после обёртывания — обещание пакета, на нём
        -- держится `without` у чужой готовой цепочки. Поэтому на каждом
        -- запросе сверяется отметка состава — одно сравнение вместо
        -- целой сборки.
        if built_from ~= chain.stamp then
            pass = compose(chain.layers, handler)
            built_from = chain.stamp
        end

        return pass(context)
    end
end

--- Оборачивает обработчик цепочкой.
---
--- Проход собирается один раз на состав слоёв. Правку через `use`,
--- `before`, `after`, `without` возвращённая функция видит сразу —
--- у состава есть отметка, и она сверяется перед каждым проходом, —
--- а правку в обход этих методов (`chain.layers[1] = ...` руками)
--- не заметит: отметку та не меняет.
---@param handler fun(context: any): any, any
---@return fun(context: any): any, any
function Chain:wrap(handler)
    local handle = blame.call(wrapped, self, handler)

    return handle
end

--- Проводит контекст через цепочку до обработчика и обратно.
---@param context any
---@param handler fun(context: any): any, any
---@return any response
---@return any err
function Chain:run(context, handler)
    local handle = blame.call(wrapped, self, handler)

    return handle(context)
end

return Module
