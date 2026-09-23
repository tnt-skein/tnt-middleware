--- Слой `cors`: межсайтовые запросы по списку разрешённых источников.
---
--- Сценарий страницы одного сайта читает ответ другого только с его
--- разрешения. Браузер называет заголовком `Origin`, чей сценарий шлёт
--- запрос, и отдаёт ответ сценарию, лишь если в ответе стоит
--- `Access-Control-Allow-Origin` с этим источником. Запрос, который браузер
--- без спроса чужому узлу не пошлёт, — способ сверх GET, HEAD и POST, свой
--- заголовок, тело JSON, — идёт после предварительного: `OPTIONS`
--- с `Access-Control-Request-Method`, на который узел отвечает, что он
--- разрешает. На предварительный запрос слой отвечает сам, не зовя
--- обработчика, а ответам на прочие ставит заголовки разрешения.
---
---     middleware.chain({
---         { 'cors', {
---             origins = { 'https://app.example.org', 'https://admin.example.org' },
---             methods = { 'PUT', 'PATCH', 'DELETE' },
---             headers = { 'content-type', 'authorization' },
---             expose = { 'x-request-id' },
---             max_age = 600,
---             credentials = true,
---         }, path = '/api' },
---     })
---
--- **Умолчания строгие: разрешено только названное.** Источники — список,
--- и без него слой не собирается. Способы сверх GET, HEAD и POST, заголовки
--- запроса сверх тех, что браузер шлёт без спроса, заголовки ответа, видные
--- сценарию, срок памяти предварительного ответа и учётные данные (куки,
--- `Authorization`) — только названные. Забытое разрешение браузер покажет
--- отказом в консоли разработчика, а лишнего не покажет никто.
---
--- **Источник — точный либо образцом поддомена.** `https://app.example.org`
--- сверяется строкой целиком, а звёздочка первым участком узла — `*.example.org`
--- после схемы `https:` — берёт любой поддомен с той же схемой и портом,
--- но не сам `example.org`. Образец Lua здесь не взят нарочно:
--- в `https://.*example.org` точка значит «любой знак», и под образец
--- встаёт `https://evilexample.org`, а без якоря в конце —
--- `https://example.org.evil.com`. Звёздочка стоит только целым первым
--- участком узла, и над ней не меньше двух участков: `*.com` разрешил бы
--- всем.
---
--- **`*` вместе с учётными данными отвергается при сборке.** Такой ответ
--- браузер не примет, а подставить вместо звёздочки пришедший источник —
--- значит разрешить чтение с куками посетителя любому сайту на свете.
--- Источник `null` отвергается по той же причине: его присылают песочницы
--- и локальные файлы любого сайта.
---
--- **Ответ по списку всегда получает `Vary: Origin`** — и ответ без
--- разрешения тоже. Заголовки такого ответа зависят от `Origin`, и кэш
--- по дороге без `Vary` отдал бы сохранённый ответ одного источника
--- другому: разрешение пришло бы не тому, кому выдано, либо не пришло тому,
--- кому положено.
---
--- **Предварительный запрос с чужого источника — отказ 403** парой
--- `nil, err` по договору отказа границы HTTP: роутер пишет о нём в журнал
--- и рисует ответ, как любой другой отказ, а обработчик не зовётся.
--- Способ и заголовки, о которых спрашивает браузер, слой не судит: он
--- называет свои списки, а сверяет их браузер — и он же говорит
--- разработчику, чего именно не хватило.
---
--- **Простой запрос с чужого источника проходит, но без разрешения.**
--- Межсайтовые заголовки — не запрет для узла, а разрешение браузеру
--- показать ответ сценарию: запрос, пришедший без спроса, дошёл бы
--- до обработчика и без слоя. Отказывать чужим формам — дело сверки токена.
---
--- **Отказ снизу получает разрешение тоже.** Отказ-таблица с числовым
--- статусом — 429 от предела частоты, 403 от сверки токена — получает
--- заголовки полем `headers`, откуда их переносит в ответ обработчик
--- отказов на границе. Без них сценарий не прочёл бы ни кода, ни тела
--- отказа и увидел бы вместо них сетевую ошибку.
---
--- **Ответ и отказ копируются, а не правятся на месте.** Обработчик вправе
--- отдавать одну и ту же таблицу на каждый запрос, и разрешение одного
--- источника, вписанное в неё, досталось бы следующим ответам — в том числе
--- на пути мимо фильтра слоя, куда разрешения не давали.
---
--- Слой — HTTP по самой сути и знает о нём больше прочих готовых слоёв:
--- читает `context.method` заглавными и заголовки `context.headers`
--- с именами в нижнем регистре (договор запроса роутера), пишет в `headers`
--- ответа и отказа. Запрос без таблицы заголовков — сообщение очереди,
--- исходящий вызов — идёт мимо нетронутым.

local must = require('tnt.must')

local Module = {}

--- Отказ предварительному запросу с чужого источника: статус, слово и код.
Module.STATUS = 403
Module.MESSAGE = 'источник запроса не разрешён'
Module.CODE = 'cors_origin_denied'

--- Ответ на разрешённый предварительный запрос: тела у него нет.
Module.PREFLIGHT_STATUS = 204

--- Что слой дописывает в `vary`.
Module.VARY = 'Origin'

--- Заголовки запроса: источник и способ, о котором спрашивает браузер.
local ORIGIN = 'origin'
local REQUEST_METHOD = 'access-control-request-method'

--- Заголовки ответа.
local ALLOW_ORIGIN = 'access-control-allow-origin'
local ALLOW_CREDENTIALS = 'access-control-allow-credentials'
local ALLOW_METHODS = 'access-control-allow-methods'
local ALLOW_HEADERS = 'access-control-allow-headers'
local EXPOSE_HEADERS = 'access-control-expose-headers'
local MAX_AGE = 'access-control-max-age'

--- «Любой»: источник, способ, заголовок.
local ANY = '*'

--- Источник: схема, `://`, узел и порт — без пути, строки запроса,
--- учётных данных, пробелов и запятых. Запятая — частая опечатка:
--- два источника одной строкой вместо двух строк списка.
local ORIGIN_SHAPE = '^%a[%w+.-]*://[^/?#@%s,]+$'

--- Образец поддомена: схема, звёздочка первым участком и узел не меньше
--- чем из двух участков, может быть, с портом.
local WILDCARD_SHAPE = '^(%a[%w+.-]*://)%*(%.[^*:]+%.[^*:]+:?%d*)$'

--- Что встаёт на место звёздочки: участки узла, ни пути, ни порта.
local SUBDOMAIN = '[%w%-_.]+'

--- Знак, которого не бывает в имени способа или заголовка: имя — это
--- `tchar` RFC 9110 (§5.6.2). Ищется чужой знак, а не имя целиком:
--- пустое имя отсекает ещё проверка настроек.
local NOT_TOKEN = "[^%w!#%$%%&'%*%+%-%.%^_`|~]"

--- Списки имён: настройка и регистр, к которому имена приводятся.
---
--- Способ — заглавными: так его шлёт браузер, и `put` в списке иначе
--- не совпал бы с `PUT`. Заголовки — строчными: их имена нечувствительны
--- к регистру, а строчными их пишет роутер.
local LISTS = {
    { field = 'methods', case = string.upper },
    { field = 'headers', case = string.lower },
    { field = 'expose', case = string.lower },
}

--- Бросок: источников нет.
local NO_ORIGINS = 'настройки слоя cors.origins — непустой список источников: '
    .. 'пустой не разрешает никого, и слой только кажется настроенным'

--- Бросок: источник не того вида.
local NOT_AN_ORIGIN = 'настройки слоя cors.origins[%d] — источник вида https://app.example.org: '
    .. 'схема и узел, без пути и косой черты в конце, а не «%s»'

--- Бросок: звёздочка не на своём месте.
---
--- Пример склеен из двух строк: пару «косая черта, звёздочка» генератор
--- мутантов читает началом комментария и не видит кода за ней.
local BAD_WILDCARD = 'настройки слоя cors.origins[%d] — звёздочка только целым первым участком узла, '
    .. 'и над ней не меньше двух участков: https://'
    .. '*.example.org, а не «%s»'

--- Бросок: источник `null`.
local NULL_ORIGIN = 'настройки слоя cors.origins[%d]: источник «null» присылают песочницы '
    .. 'и локальные файлы любого сайта — разрешить его значит разрешить всем'

--- Бросок: любой источник вместе с учётными данными.
local ANY_WITH_CREDENTIALS = 'настройки слоя cors: источник «*» вместе с credentials браузер отвергает, '
    .. 'а подставить вместо него пришедший источник — значит отдать ответы с куками посетителя '
    .. 'любому сайту; назовите источники списком'

--- Бросок: звёздочка в списке имён вместе с учётными данными.
local ANY_NAME_WITH_CREDENTIALS = 'настройки слоя cors.%s: звёздочку вместе с credentials браузер '
    .. 'читает не как «любой», а как имя «*» — назовите имена списком'

--- Бросок: в строке списка не одно имя.
local NOT_A_NAME =
    'настройки слоя cors.%s[%d] — одно имя без пробелов и запятых, а не «%s»'

--- Почему отказали предварительному запросу; для журнала.
local NOT_LISTED = 'источник «%s» не в списке разрешённых'

--- Описание настроек слоя.
---
--- `tag` здесь потому, что реестр кладёт свою метку журнала в настройки
--- каждого слоя; этому она не нужна — своих записей он не пишет.
local OPTIONS = {
    origins = { 'array_of', 'not_empty' },
    methods = { '?array_of', 'not_empty' },
    headers = { '?array_of', 'not_empty' },
    expose = { '?array_of', 'not_empty' },
    max_age = '?integer',
    credentials = '?boolean',
    tag = '?string',
}

---@class TntMiddlewareCorsOptions
---@field origins string[] Разрешённые источники: точные, образцом поддомена (`*.example.org` после схемы) либо `*`
---@field methods string[]|nil Способы сверх GET, HEAD и POST
---@field headers string[]|nil Заголовки запроса сверх тех, что браузер шлёт без спроса
---@field expose string[]|nil Заголовки ответа, видные сценарию
---@field max_age integer|nil Сколько секунд браузер помнит ответ на предварительный запрос
---@field credentials boolean|nil Пускать ли с куками и `Authorization`; по умолчанию нет
---@field tag string|nil Метка журнала; её кладёт реестр, слою она не нужна

---@class TntMiddlewareCorsPolicy
---@field any boolean Разрешён любой источник
---@field exact table<string, boolean> Точные источники строчными
---@field patterns string[] Образцы Lua, собранные из образцов поддомена

--- Отказ строкой — для журнала.
---
--- Роутер и перехват пишут отказ `tostring`, и таблица без этого ушла бы
--- в запись как `table: 0x…`.
local REFUSAL = {
    __tostring = function(refusal)
        return ('%s: %s'):format(refusal.message, refusal.reason)
    end,
}

--- Строка буквально — как часть образца Lua.
---@param text string
---@return string
local function literal(text)
    return (text:gsub('%p', function(sign)
        return '%' .. sign
    end))
end

--- Разбирает список источников.
---
--- Источник сверяется строчными: схему и узел браузер шлёт строчными,
--- и `https://App.example.org` из настройки иначе не совпал бы ни с кем.
---@param list string[]
---@return TntMiddlewareCorsPolicy|nil policy
---@return string|nil problem
local function origins_of(list)
    ---@type TntMiddlewareCorsPolicy
    local policy = { any = false, exact = {}, patterns = {} }

    for index, given in ipairs(list) do
        local origin = given:lower()

        if origin == ANY then
            policy.any = true
        elseif origin == 'null' then
            return nil, NULL_ORIGIN:format(index)
        elseif origin:find(ORIGIN_SHAPE) == nil then
            return nil, NOT_AN_ORIGIN:format(index, given)
        elseif origin:find('%*') == nil then
            policy.exact[origin] = true
        else
            local head, tail = origin:match(WILDCARD_SHAPE)

            if head == nil then
                return nil, BAD_WILDCARD:format(index, given)
            end

            -- Совпал образец — совпали обе его части.
            ---@cast tail string

            -- Образец собирается из букв настройки, а не пишется ею:
            -- знаки в схеме и узле идут буквально, и `.` в них не станет
            -- «любым знаком».
            table.insert(policy.patterns, '^' .. literal(head) .. SUBDOMAIN .. literal(tail) .. '$')
        end
    end

    return policy
end

--- Имена одного списка, приведённые к одному регистру.
---@param list string[]|nil
---@param field string Имя настройки: войдёт в текст отказа
---@param case fun(name: string): string
---@param credentials boolean
---@return string[]|nil names
---@return string|nil problem
local function names_of(list, field, case, credentials)
    local names = {}

    for index, name in ipairs(list or {}) do
        if name:find(NOT_TOKEN) ~= nil then
            return nil, NOT_A_NAME:format(field, index, name)
        end

        if credentials and name == ANY then
            return nil, ANY_NAME_WITH_CREDENTIALS:format(field)
        end

        table.insert(names, case(name))
    end

    return names
end

--- Список имён значением заголовка; пустой — никакого.
---@param names string[]
---@return string|nil
local function joined(names)
    if #names > 0 then
        return table.concat(names, ', ')
    end
end

--- Разрешён ли источник: чем ответить в `Access-Control-Allow-Origin`
--- либо ничего.
---
--- Разрешённый по списку отвечается своим же значением, как прислан:
--- браузер сверяет заголовок с источником побайтно.
---@param policy TntMiddlewareCorsPolicy
---@param origin any
---@return string|nil
local function allowed(policy, origin)
    if policy.any then
        return ANY
    end

    if type(origin) ~= 'string' then
        return nil
    end

    local lowered = origin:lower()

    if policy.exact[lowered] then
        return origin
    end

    for _, pattern in ipairs(policy.patterns) do
        if lowered:find(pattern) ~= nil then
            return origin
        end
    end
end

--- Дописывает `Origin` в `vary`.
---
--- Значение не строкой (список значений заголовка) слой не разбирает
--- и оставляет как есть. `*` уже значит «по всему», и дописывать к нему
--- нечего.
---@param current any
---@return any
local function varied(current)
    if current == nil or current == '' then
        return Module.VARY
    end

    if type(current) ~= 'string' then
        return current
    end

    -- Имена сверяются целыми элементами списка: `X-Origin-Id` — не `Origin`.
    local listed = ',' .. (current:lower():gsub('%s', '')) .. ','

    if listed:find(',origin,') ~= nil or listed:find(',%*,') ~= nil then
        return current
    end

    return current .. ', ' .. Module.VARY
end

--- Заголовки ответа: прежние, поверх них — разрешение, если оно есть.
---@param headers table|nil Прежние заголовки
---@param base table<string, string|nil> Что ставится вместе с разрешением
---@param allow string|nil Значение `Access-Control-Allow-Origin`
---@param vary boolean Дописать ли `Origin` в `vary`
---@return table
local function merged(headers, base, allow, vary)
    local result = {}

    for name, value in pairs(headers or {}) do
        result[name] = value
    end

    if allow ~= nil then
        for name, value in pairs(base) do
            result[name] = value
        end

        -- Своё перебивает поставленное обработчиком: межсайтовые
        -- заголовки — дело слоя, и два хозяина у одного разрешения
        -- дали бы сочетание, которого не задумывал ни один.
        result[ALLOW_ORIGIN] = allow
    end

    if vary then
        result.vary = varied(result.vary)
    end

    return result
end

--- Копия ответа или отказа с заголовками разрешения.
---
--- Копия, а не правка на месте: таблицу обработчик вправе отдавать
--- на каждый запрос, и разрешение одного источника уехало бы в следующие
--- ответы. Метатаблица сохраняется — по ней узнают свои отказы,
--- ей же они пишутся строкой; берётся она мимо `__metatable`, иначе
--- закрытая метатаблица подменилась бы своей заглушкой.
---
--- Заголовки не таблицей слой не трогает: ставить некуда, а сервер
--- о такой ответ споткнётся и без слоя.
---@param value table
---@param base table<string, string|nil>
---@param allow string|nil
---@param vary boolean
---@return table
local function stamped(value, base, allow, vary)
    local headers = value.headers

    if headers ~= nil and type(headers) ~= 'table' then
        return value
    end

    local copy = {}

    for key, field in pairs(value) do
        copy[key] = field
    end

    copy.headers = merged(headers, base, allow, vary)

    return setmetatable(copy, debug.getmetatable(value))
end

--- Отказ предварительному запросу с чужого источника.
---
--- Отказ бывает только у разрешения по списку, и `Vary` у него поэтому
--- есть всегда.
---@param origin any
---@return table
local function refusal_of(origin)
    return setmetatable({
        status = Module.STATUS,
        message = Module.MESSAGE,
        code = Module.CODE,
        reason = NOT_LISTED:format(tostring(origin)),
        headers = { vary = Module.VARY },
    }, REFUSAL)
end

--- Собирает слой.
---
--- Негодные настройки — бросок при сборке, на строку того, кто собирает:
--- опечатка в источнике обязана найтись при объявлении цепочки, а не тогда,
--- когда браузер откажет посетителю.
---@param opts TntMiddlewareCorsOptions
---@return TntMiddlewareFn
function Module.new(opts)
    local caller = must.at(2)

    caller.options(opts, 'настройки слоя cors', OPTIONS)
    caller.optional.non_negative(opts.max_age, 'настройки слоя cors.max_age')

    if #opts.origins == 0 then
        error(NO_ORIGINS, 2)
    end

    local policy, problem = origins_of(opts.origins)

    if policy == nil then
        error(problem, 2)
    end

    local credentials = opts.credentials == true

    if credentials and policy.any then
        error(ANY_WITH_CREDENTIALS, 2)
    end

    local lists = {}

    for _, list in ipairs(LISTS) do
        local names, wrong = names_of(opts[list.field], list.field, list.case, credentials)

        if names == nil then
            error(wrong, 2)
        end

        lists[list.field] = names
    end

    -- Что ставится вместе с разрешением: у предварительного ответа —
    -- способы, заголовки и срок, у прочих — видные сценарию заголовки;
    -- учётные данные — у обоих.
    local preflight = {
        [ALLOW_METHODS] = joined(lists.methods),
        [ALLOW_HEADERS] = joined(lists.headers),
    }
    local actual = { [EXPOSE_HEADERS] = joined(lists.expose) }

    if opts.max_age ~= nil then
        preflight[MAX_AGE] = tostring(opts.max_age)
    end

    if credentials then
        preflight[ALLOW_CREDENTIALS] = 'true'
        actual[ALLOW_CREDENTIALS] = 'true'
    end

    -- Разрешение «любому» от `Origin` не зависит, и `Vary` ему не нужен:
    -- лишний `Vary` дробит кэш по дороге на копию под каждый источник.
    local vary = not policy.any

    return function(context, next_layer)
        local headers = type(context) == 'table' and context.headers or nil

        if type(headers) ~= 'table' then
            return next_layer(context)
        end

        local origin = headers[ORIGIN]
        local allow = allowed(policy, origin)

        -- Предварительный запрос узнаётся по всем трём признакам: `OPTIONS`
        -- без источника или без спрошенного способа — обычный запрос,
        -- и отвечать на него роутеру.
        if origin ~= nil and context.method == 'OPTIONS' and headers[REQUEST_METHOD] ~= nil then
            if allow == nil then
                return nil, refusal_of(origin)
            end

            return { status = Module.PREFLIGHT_STATUS, headers = merged(nil, preflight, allow, vary) }
        end

        local response, err = next_layer(context)

        if type(response) == 'table' then
            response = stamped(response, actual, allow, vary)
        end

        -- Отказ узнаётся по договору границы HTTP — по числовому статусу:
        -- заголовки из него переносит в ответ обработчик отказов.
        if type(err) == 'table' and type(err.status) == 'number' then
            err = stamped(err, actual, allow, vary)
        end

        return response, err
    end
end

return Module
