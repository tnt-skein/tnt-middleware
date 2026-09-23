--- Фильтр слоя: по пути и способу запроса.
---
--- Слой, нужный не всякому запросу, — CORS только под `/api`, счётчик
--- только на `POST /login`, — без фильтра вешался бы на каждую группу
--- маршрутов руками, а в цепочку, стоящую до поиска маршрута (вокруг 404),
--- не встал бы никак. Фильтр пишется в записи цепочки рядом с именем:
---
---     { 'cors', { origins = { 'https://app.example.org' } }, path = '/api' }
---     { 'throttle', { per_minute = 60 }, path = '/login', method = 'POST' }
---     { 'web', path = '/panel' }          -- группа: фильтр у каждого её слоя
---
--- Запрос мимо фильтра идёт мимо слоя — как будто того в цепочке нет:
--- слой не зовётся ни на входе, ни на выходе.
---
--- Путь — начало пути по участкам, а не шаблон Lua: `/api` накрывает
--- `/api` и всё под ним (`/api/customers`), но не `/apix`. Шаблон здесь
--- не взят нарочно: маршруты делят путь косой чертой на участки и ищутся
--- по ним, а не образцом, и образец принёс бы три ловушки разом —
--- `.` в `/v1.0/` значит «любой знак», без якоря `/api/` находится
--- и в `/docs/api/`, а негодный образец Lua разбирает лениво и бросает
--- не при объявлении, а на запросе, чей путь дошёл до негодного места.
--- Знаки образца в пути — `*`, `?`, `^`, `$` — отвергаются при объявлении,
--- чтобы `'/api/.*'` не стал фильтром, который не проходит никто.
--- Способ сверяется без учёта регистра.
---
--- Фильтр читает `context.path` и `context.method` — единственное, что сама
--- цепочка знает о виде запроса; прочее знание о HTTP живёт в готовых
--- слоях, каждому своё. Запрос без них — не таблица, сообщение очереди
--- без пути — фильтр не проходит: слой, поставленный «только под /api»,
--- на запрос без пути ставить не просили.
---
--- Отказы фильтра бросаются без места: фильтр разбирают при объявлении
--- цепочки, и место — строку объявления — приписывает вход цепочки
--- (`tnt.middleware.blame`).

local fail = require('tnt.must.fail')

local Module = {}

---@alias TntMiddlewareOnly fun(context: any): boolean

---@class TntMiddlewareFilterFields
---@field path string|nil Начало пути запроса по участкам
---@field method string|string[]|nil Способ или список способов

--- Поля записи, из которых собирается фильтр.
Module.FIELDS = { 'path', 'method' }

--- Знаки образца Lua, которых в начале пути не бывает.
---
--- Путь с ними — образец, написанный по привычке от рока http, и как
--- начало пути он не подошёл бы ни одному запросу. Точка и процент
--- сюда не входят: `/v1.0` и `/%D0%B0` — обычные пути.
local PATTERN_MARKS = '[%*%?%^%$]'

--- Проверенное начало пути: без хвостовой косой черты.
---
--- Косая черта в конце снимается, чтобы `/api` и `/api/` значили одно:
--- сам путь и всё под ним. Корень при этом становится пустым началом,
--- под которым лежит всё.
---@param path any
---@return string
local function prefix_of(path)
    -- Образец узнаётся раньше косой черты: `^/api` — тоже образец,
    -- и сказать об этом полезнее, чем о недостающей черте.
    if type(path) == 'string' and path:find(PATTERN_MARKS) ~= nil then
        fail.raise(
            ('путь в фильтре слоя — начало пути, а не образец: «%s»; '):format(
                path
            ) .. '`/api` накрывает `/api` и всё под ним'
        )
    end

    if type(path) ~= 'string' or not path:startswith('/') then
        fail.raise(
            ('путь в фильтре слоя — начало пути с косой черты, а не «%s»'):format(
                tostring(path)
            )
        )
    end

    -- Пустого участка в пути не бывает: `/api//` — опечатка, и как начало
    -- пути такой фильтр не прошёл бы никто.
    if path:find('//') ~= nil then
        fail.raise(
            ('путь в фильтре слоя — начало пути по участкам, а в «%s» пустой участок'):format(
                path
            )
        )
    end

    return (path:gsub('/$', ''))
end

--- Способы фильтра множеством, заглавными.
---
--- Пустой список — не «любой способ», а опечатка: слой с фильтром, который
--- не проходит ни один запрос, стоял бы в цепочке мёртвым.
---@param method any
---@return table<string, boolean>
local function methods_of(method)
    local listed = method

    if type(method) == 'string' then
        listed = { method }
    end

    if type(listed) ~= 'table' or #listed == 0 then
        fail.raise(
            ('способ в фильтре слоя — имя или непустой список имён, а не «%s»'):format(
                tostring(method)
            )
        )
    end

    local set = {}

    for _, name in ipairs(listed) do
        if type(name) ~= 'string' or name == '' then
            fail.raise(
                ('способ в фильтре слоя — непустая строка, а не «%s»'):format(
                    tostring(name)
                )
            )
        end

        set[name:upper()] = true
    end

    return set
end

--- Поддерево путей: начало без хвостовой косой черты и оно же с ней.
---@class TntMiddlewareSubtree
---@field prefix string Начало без хвостовой косой черты: `/api`
---@field head string То же начало с косой чертой: `/api/`

--- Лежит ли путь в поддереве: он сам либо участок глубже.
---
--- Начало сравнивается вместе с косой чертой: `/api/` — начало
--- `/api/customers`, но не `/apix`. Черта дописана при объявлении, а не
--- здесь: склейка на каждом запросе — та плата, которую потом ищут
--- профилем.
---@param path any Путь запроса
---@param subtree TntMiddlewareSubtree
---@return boolean
local function under(path, subtree)
    return type(path) == 'string' and (path == subtree.prefix or path:startswith(subtree.head))
end

--- Собирает фильтр из полей записи; без полей — пусто.
---
--- Проверка полей стоит здесь, при объявлении цепочки, а не при первом
--- запросе: фильтр пишется кодом, и опечатка в нём обязана обнаружиться,
--- когда отвечать ещё некому.
---@param fields TntMiddlewareFilterFields
---@return TntMiddlewareOnly|nil
function Module.of(fields)
    ---@type TntMiddlewareSubtree|nil
    local subtree
    local methods

    if fields.path ~= nil then
        local prefix = prefix_of(fields.path)

        subtree = { prefix = prefix, head = prefix .. '/' }
    end

    if fields.method ~= nil then
        methods = methods_of(fields.method)
    end

    if subtree == nil and methods == nil then
        return nil
    end

    return function(context)
        if type(context) ~= 'table' then
            return false
        end

        if subtree ~= nil and not under(context.path, subtree) then
            return false
        end

        if methods ~= nil then
            if type(context.method) ~= 'string' or not methods[context.method:upper()] then
                return false
            end
        end

        return true
    end
end

--- Оба фильтра разом.
---
--- Слой в группе бывает со своим фильтром, а группу берут в цепочку
--- с ещё одним: `{ 'web', path = '/panel' }`. Слой проходит оба, а не
--- последний: сузить группу — не значит снять то, что слой поставил себе.
---@param inner TntMiddlewareOnly|nil Фильтр самого слоя
---@param outer TntMiddlewareOnly Фильтр записи, по которой слой взяли
---@return TntMiddlewareOnly
function Module.both(inner, outer)
    if inner == nil then
        return outer
    end

    return function(context)
        return inner(context) and outer(context)
    end
end

return Module
