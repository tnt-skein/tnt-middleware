--- Реестр слоёв и групп: из чего собираются цепочки.
---
--- Слой объявляется не готовой функцией, а фабрикой `(параметры) -> слой`.
--- Иначе один и тот же слой нельзя завести дважды с разной настройкой:
--- ограничение в шестьдесят запросов в минуту для чужих и в тысячу для
--- своих — это два слоя из одной фабрики, а не два разных слоя.
---
--- Параметры задаются таблицей, а не строкой вида `throttle:60,1`.
--- Строку пришлось бы разбирать, а разбор чисел из строки ошибается молча:
--- опечатка в ней становится нулём, а ноль запросов в минуту — отказ всем.
--- В таблице опечатка видна глазом и проверяется самим слоём.
---
--- Группа — список записей под одним именем: `web`, `api` и прочие наборы
--- слоёв объявляются один раз на приложение. Записи группы разбираются в
--- тот миг, когда группу берут в цепочку, а не когда её объявляют: иначе
--- порядок объявлений в настройке стал бы значимым, и группа не смогла бы
--- сослаться на слой, объявленный ниже.
---
--- Запись цепочки — сам слой, имя слоя или группы либо список
--- `{ имя, параметры }`; названными полями в нём идут имя слоя в цепочке
--- (`name`) и фильтр по запросу (`path`, `method` — `tnt.middleware.filter`).
--- Прочие названные поля — отказ: фильтр с опечаткой в имени поля молча
--- поставил бы слой на всё.
---
--- Отказы объявлений бросаются без места, а место — строку приложения —
--- приписывают входы: `new`, `register`, `group` и `chain`
--- (`tnt.middleware.blame`). Разбор записи уходит вглубь на столько
--- кадров, сколько вложено групп, и уровень `error`, посчитанный здесь,
--- показывал бы внутрь пакета.

local fail = require('tnt.must.fail')

local blame = require('tnt.middleware.blame')
local chain = require('tnt.middleware.chain')
local filter = require('tnt.middleware.filter')
local common = require('tnt.middleware.layer.common')
local cors_layer = require('tnt.middleware.layer.cors')
local log_layer = require('tnt.middleware.layer.log')
local request_id_layer = require('tnt.middleware.layer.request_id')
local request_id_header_layer = require('tnt.middleware.layer.request_id_header')
local rescue_layer = require('tnt.middleware.layer.rescue')
local timing_layer = require('tnt.middleware.layer.timing')

local Module = {}

--- Метка журнала готовых слоёв, если приложение не назвало свою.
local DEFAULT_TAG = 'tnt.middleware'

--- Слои, объявленные в каждом реестре.
---
--- Только те, что не тянут за собой чужих пакетов: ограничение частоты
--- поверх Redis и запись следов в Sentry живут в тех пакетах, а не здесь.
--- Межсайтовые заголовки — здесь: им довольно заголовков запроса и ответа.
Module.BUILTIN = {
    cors = cors_layer.new,
    log = log_layer.new,
    timing = timing_layer.new,
    rescue = rescue_layer.new,
    request_id = request_id_layer.new,
    request_id_header = request_id_header_layer.new,
}

---@class TntMiddlewareOptions
---@field tag string|nil Метка журнала готовых слоёв
---@field layers table<string, fun(options: table): TntMiddlewareFn>|nil Свои слои
---@field groups table<string, any[]>|nil Свои группы

---@class TntMiddleware
---@field tag string Метка журнала готовых слоёв
---@field layers table<string, fun(options: table): TntMiddlewareFn> Фабрики по именам
---@field groups table<string, any[]> Списки записей по именам
local Registry = {}
Registry.__index = Registry

--- Имена из таблицы по алфавиту: перечисление вразнобой мешает читать.
---@param source table
---@return string[]
local function sorted_names(source)
    local names = {}

    for name in pairs(source) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

--- Всё, что объявлено в реестре, — слои и группы вместе.
---@param registry TntMiddleware
---@return string
local function declared(registry)
    -- Складываются сами объявления, а не пометки «есть такое имя»: список
    -- нужен по именам, а имя, объявленное и слоем, и группой, в нём должно
    -- остаться одно.
    local merged = {}

    for name, factory in pairs(registry.layers) do
        merged[name] = factory
    end

    for name, entries in pairs(registry.groups) do
        merged[name] = entries
    end

    return table.concat(sorted_names(merged), ', ')
end

--- Имя слоя или группы.
---@param name any
local function check_name(name)
    if type(name) ~= 'string' or name == '' then
        fail.raise(
            ('имя слоя или группы — непустая строка, а не «%s»'):format(
                tostring(name)
            )
        )
    end
end

--- Объявление слоя.
---@param name any
---@param factory any
local function check_layer(name, factory)
    check_name(name)

    if type(factory) ~= 'function' then
        fail.raise(
            ('слой «%s» объявляется фабрикой: функцией (параметры) -> слой, а не %s'):format(
                tostring(name),
                type(factory)
            )
        )
    end
end

--- Объявление группы.
---@param name any
---@param entries any
local function check_group(name, entries)
    check_name(name)

    if type(entries) ~= 'table' then
        fail.raise(
            ('группа «%s» объявляется списком записей, а не %s'):format(
                tostring(name),
                type(entries)
            )
        )
    end
end

--- Объявления одного рода целиком.
---@param value any Таблица объявлений или nil
---@param what string Как назвать их в тексте отказа
---@param check fun(name: any, declaration: any)
local function check_all(value, what, check)
    if value == nil then
        return
    end

    if type(value) ~= 'table' then
        fail.raise(('%s объявляются таблицей, а не %s'):format(what, type(value)))
    end

    for name, declaration in pairs(value) do
        check(name, declaration)
    end
end

--- Настройки целиком.
---
--- Проверяются до того, как собран хоть один слой: ошибка в объявлениях
--- обязана обнаружиться при настройке, а не на первом запросе, когда
--- отвечать уже надо. Отказ — без места: его приписывает тот, кто
--- проверку позвал, — `new` здесь и `configure` у фасада.
---@param opts TntMiddlewareOptions|nil
---@return TntMiddlewareOptions
function Module.check(opts)
    local settings = opts or {}

    -- Метка уходит журналу именем, и сверяется она правилом имени,
    -- а не как строка: `моё приложение` иначе дошло бы до сборки
    -- первого слоя и только там отказало бы.
    local refusal = common.tag_refusal(settings.tag)

    if refusal ~= nil then
        fail.raise(refusal)
    end

    check_all(settings.layers, 'слои', check_layer)
    check_all(settings.groups, 'группы', check_group)

    return settings
end

--- Объявляет слой под именем, без места в отказе.
---@param registry TntMiddleware
---@param name any
---@param factory any
local function declare_layer(registry, name, factory)
    check_layer(name, factory)
    registry.layers[name] = factory
end

--- Объявляет группу под именем, без места в отказе.
---@param registry TntMiddleware
---@param name any
---@param entries any
local function declare_group(registry, name, entries)
    check_group(name, entries)
    registry.groups[name] = entries
end

--- Собирает реестр, без места в отказе.
---@param opts TntMiddlewareOptions|nil
---@return TntMiddleware
local function assembled(opts)
    local settings = Module.check(opts)

    ---@type TntMiddleware
    local registry = setmetatable({
        tag = settings.tag or DEFAULT_TAG,
        layers = {},
        groups = {},
    }, Registry)

    for name, factory in pairs(Module.BUILTIN) do
        declare_layer(registry, name, factory)
    end

    -- Объявления приложения идут после готовых: имя, занятое готовым
    -- слоем, приложение вправе забрать себе — свой слой журнала бывает
    -- ближе к делу, чем общий.
    for name, factory in pairs(settings.layers or {}) do
        declare_layer(registry, name, factory)
    end

    for name, entries in pairs(settings.groups or {}) do
        declare_group(registry, name, entries)
    end

    return registry
end

--- Заводит реестр со своими объявлениями.
---@param opts TntMiddlewareOptions|nil
---@return TntMiddleware
function Module.new(opts)
    local registry = blame.call(assembled, opts)

    return registry
end

--- Объявляет слой под именем.
---@param name string
---@param factory fun(options: table): TntMiddlewareFn
---@return TntMiddleware
function Registry:register(name, factory)
    blame.call(declare_layer, self, name, factory)

    return self
end

--- Объявляет группу слоёв под именем.
---@param name string
---@param entries any[]
---@return TntMiddleware
function Registry:group(name, entries)
    blame.call(declare_group, self, name, entries)

    return self
end

--- Собирает слой фабрикой.
---@param name string
---@param factory fun(options: table): TntMiddlewareFn
---@param options table|nil
---@return TntMiddlewareFn
function Registry:build(name, factory, options)
    if options ~= nil and type(options) ~= 'table' then
        -- Вторым местом в записи стоит не имя соседнего слоя, а параметры
        -- этого: `{ 'log', 'rescue' }` — это слой журнала с непонятными
        -- параметрами, а два слоя подряд — две записи.
        fail.raise(
            ('параметры слоя «%s» — таблица, а не %s: '):format(name, type(options))
                .. 'соседний слой пишется отдельной записью'
        )
    end

    -- Метка журнала достаётся слою от реестра: записи всего конвейера
    -- должны находиться в журнале одним запросом, а повторять метку
    -- в каждом слое — значит однажды её не повторить.
    local prepared = { tag = self.tag }

    for key, value in pairs(options or {}) do
        prepared[key] = value
    end

    -- Фабрика зовётся под `pcall`, и кадр над ней — не строка пакета:
    -- фабрика, винящая своего вызывающего (`error(текст, 2)`, как слой
    -- `cors`), бросает текст без места, а место, строку объявления
    -- цепочки, приписывает вход. Позови её пакет напрямую, её вина легла
    -- бы на эту строку.
    local built, layer = pcall(factory, prepared)

    if not built then
        fail.raise(layer)
    end

    if type(layer) ~= 'function' then
        fail.raise(('слой «%s» собрался не функцией, а %s'):format(name, type(layer)))
    end

    return layer
end

--- Разворачивает объявленное имя в слои.
---@param name string Имя слоя или группы
---@param options table|nil Параметры слоя
---@param label string|nil Под каким именем слой встанет в цепочку
---@param seen table<string, boolean>|nil Группы, раскрытые по дороге сюда
---@return TntMiddlewareLayer[]
function Registry:expand(name, options, label, seen)
    local factory = self.layers[name]

    if factory ~= nil then
        return { { name = label, fn = self:build(name, factory, options) } }
    end

    local entries = self.groups[name]

    if entries == nil then
        fail.raise(
            ('слой или группа «%s» не объявлены; объявлены: %s'):format(
                name,
                declared(self)
            )
        )
    end

    if options ~= nil then
        fail.raise(
            ('группе «%s» параметры не передать: их принимают слои по одному'):format(
                name
            )
        )
    end

    seen = seen or {}

    if seen[name] then
        fail.raise(('группа «%s» включает саму себя'):format(name))
    end

    -- Пометка снимается на обратном ходу: круг — это группа, встретившаяся
    -- сама себе по дороге вниз, а не дважды упомянутая в разных ветках.
    seen[name] = true

    local layers = {}

    for _, entry in ipairs(entries) do
        for _, layer in ipairs(self:resolve(entry, seen)) do
            table.insert(layers, layer)
        end
    end

    seen[name] = nil

    return layers
end

--- Названные поля записи, которые здесь понимают: имя слоя и фильтр.
local KNOWN_FIELDS = { name = true }

for _, field in ipairs(filter.FIELDS) do
    KNOWN_FIELDS[field] = true
end

--- Проверяет, что названных полей, кроме понятных, в записи нет.
---
--- Опечатка в имени поля фильтра — `paths`, `methods` — иначе прошла бы
--- молча, и слой, задуманный под `/api/`, встал бы на всё. Места записи
--- (`[1]`, `[2]`) не проверяются: их разбирает сам `resolve`.
---@param entry table
local function check_fields(entry)
    for key in pairs(entry) do
        if type(key) == 'string' and not KNOWN_FIELDS[key] then
            fail.raise(
                ('в записи цепочки неизвестное поле «%s»; есть name, %s'):format(
                    key,
                    table.concat(filter.FIELDS, ', ')
                )
            )
        end
    end
end

--- Ставит фильтр записи на каждый её слой.
---
--- У записи с именем группы слоёв несколько, и фильтр достаётся каждому;
--- слой, у которого в группе уже есть свой, проходит оба.
---@param layers TntMiddlewareLayer[]
---@param only TntMiddlewareOnly|nil
---@return TntMiddlewareLayer[]
local function narrowed(layers, only)
    if only == nil then
        return layers
    end

    for _, layer in ipairs(layers) do
        layer.only = filter.both(layer.only, only)
    end

    return layers
end

--- Разбирает запись цепочки в список слоёв.
---
--- Записью бывает сам слой, имя объявленного слоя или группы, а также
--- список `{ имя, параметры }` — и в нём же задаётся имя слоя в цепочке
--- полем `name`, когда одна фабрика нужна дважды, и фильтр по запросу
--- полями `path` и `method`.
---@param entry any
---@param seen table<string, boolean>|nil
---@return TntMiddlewareLayer[]
function Registry:resolve(entry, seen)
    if type(entry) == 'function' then
        return { { fn = entry } }
    end

    if type(entry) == 'string' then
        return self:expand(entry, nil, entry, seen)
    end

    if type(entry) ~= 'table' then
        fail.raise(
            ('запись цепочки непонятна: ожидались слой, имя или { имя, параметры }, а не %s'):format(
                type(entry)
            )
        )
    end

    local what = entry[1]

    if type(what) ~= 'string' and type(what) ~= 'function' then
        -- Самая частая опечатка: параметры слоя положены прямо в список
        -- цепочки. Отличить их от записи нельзя — первого места в них просто
        -- нет, — зато можно сказать, как написать правильно.
        fail.raise(
            ('в записи цепочки первым идёт слой или его имя, а не %s; '):format(
                type(what)
            )
                .. "слой с параметрами пишется вложенным списком: { { 'имя', { ... } } }"
        )
    end

    check_fields(entry)

    local only = filter.of(entry)

    if type(what) == 'string' then
        return narrowed(self:expand(what, entry[2], entry.name or what, seen), only)
    end

    if entry[2] ~= nil then
        -- Функция в записи — это сам слой, а не фабрика: иначе непонятно,
        -- звать её при сборке или при запросе, и ошибка в этом выглядит
        -- как слой, который ничего не делает.
        fail.raise(
            'слою-функции параметры не передать: их принимает объявленный слой'
        )
    end

    return { { name = entry.name, fn = what, only = only } }
end

--- Собирает цепочку из записей.
---@param entries any Список записей, одно имя или nil
---@return TntMiddlewareChain
function Registry:chain(entries)
    local built = blame.call(chain.new, self, entries)

    return built
end

--- Что объявлено в реестре. Ни паролей, ни ключей здесь не бывает.
---@return { tag: string, layers: string[], groups: string[] }
function Registry:status()
    return {
        tag = self.tag,
        layers = sorted_names(self.layers),
        groups = sorted_names(self.groups),
    }
end

return Module
