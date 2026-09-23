--- Проверки слоя межсайтовых заголовков: сборка и её отказы, простой
--- и предварительный запрос, образцы поддоменов, копии ответа и отказа.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware.layer.cors')

--- Свой источник и чужие.
local APP = 'https://app.example.org'
local FOREIGN = 'https://evil.example.com'

--- Настройки, в которых разрешено всё, что умеет слой.
---@return table
local function everything()
    return {
        origins = { APP },
        methods = { 'put', 'DELETE' },
        headers = { 'Content-Type', 'authorization' },
        expose = { 'X-Request-Id', 'x-ratelimit-remaining' },
        max_age = 600,
        credentials = true,
    }
end

--- Слой из настроек — прямо фабрикой, без реестра.
---@param opts any
---@return function
local function cors(opts)
    return g.middleware.layer.cors(opts)
end

--- Запрос с заголовками, по умолчанию GET под `/api`.
---@param headers table|nil
---@param method string|nil
---@return table
local function request(headers, method)
    return { method = method or 'GET', path = '/api/customers', headers = headers or {} }
end

--- Запрос с источником.
---@param origin string|nil
---@return table
local function from(origin)
    return request({ origin = origin })
end

--- Предварительный запрос: `OPTIONS` с источником и спрошенным способом.
---@param origin string
---@return table
local function preflight(origin)
    return request({
        origin = origin,
        ['access-control-request-method'] = 'PUT',
        ['access-control-request-headers'] = 'content-type',
    }, 'OPTIONS')
end

--- Обработчик, который считает вызовы и отвечает новой таблицей.
---@return fun(context: any): table handler
---@return table calls Поле `count` — сколько раз позвали
local function counting()
    local calls = { count = 0 }

    return function(_)
        calls.count = calls.count + 1

        return { status = 200, headers = { ['content-type'] = 'application/json' }, body = '[]' }
    end,
        calls
end

--- Обработчик, отвечающий одним и тем же.
---@param response any
---@param err any
---@return fun(context: any): any, any
local function answering(response, err)
    return function(_)
        return response, err
    end
end

--- Заголовки ответа, который дал слой на запрос с обычным обработчиком.
---@param opts table
---@param context any
---@return table
local function headers_of(opts, context)
    local response = cors(opts)(context, (counting()))

    return response.headers
end

--- Отказ сборки называет строку вызывающего и говорит своё слово.
---
--- Строка вызова — первая строка тела проверяемой функции.
---@param case function
---@param message string
local function assert_blamed(case, message)
    local _, err = pcall(case)
    local info = debug.getinfo(case, 'S') --[[@as { short_src: string, linedefined: integer }]]

    t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, message))
end

-- Сборка -----------------------------------------------------------------

g.test_the_layer_is_ready_in_every_registry_and_without_one = function()
    t.assert_equals(g.middleware.layer.cors, helper.part('tnt.middleware.layer.cors').new)
    t.assert_equals(g.middleware.new():status().layers[1], 'cors')
end

g.test_without_settings_the_layer_is_not_built = function()
    assert_blamed(function()
        cors(nil)
    end, 'настройки слоя cors — таблица, а не nil')
end

g.test_without_origins_the_layer_is_not_built = function()
    assert_blamed(function()
        cors({ methods = { 'PUT' } })
    end, 'настройки слоя cors.origins — массив, а не nil')
end

-- Пустой список ничего не разрешает: такой слой только кажется настроенным.
g.test_an_empty_list_of_origins_is_refused = function()
    assert_blamed(
        function()
            cors({ origins = {} })
        end,
        'настройки слоя cors.origins — непустой список источников: '
            .. 'пустой не разрешает никого, и слой только кажется настроенным'
    )
end

g.test_one_origin_is_enough = function()
    t.assert_type(cors({ origins = { APP } }), 'function')
end

g.test_a_misspelled_setting_is_refused = function()
    assert_blamed(
        function()
            cors({ origin = APP })
        end,
        'настройки слоя cors: ключа «origin» нет, есть credentials, expose, headers, max_age, methods, origins, tag'
    )
end

g.test_max_age_is_a_whole_number_of_seconds_not_below_zero = function()
    assert_blamed(function()
        cors({ origins = { APP }, max_age = -1 })
    end, 'настройки слоя cors.max_age — число не меньше 0, а не -1')

    assert_blamed(function()
        cors({ origins = { APP }, max_age = 1.5 })
    end, 'настройки слоя cors.max_age — целое число, а не 1.5')

    -- Ноль годится: браузер тогда не помнит ответа вовсе.
    t.assert_equals(headers_of({ origins = { APP }, max_age = 0 }, preflight(APP))['access-control-max-age'], '0')
end

g.test_an_origin_is_a_scheme_and_a_host_without_a_path = function()
    for _, wrong in ipairs({
        'https://app.example.org/',
        'https://app.example.org/api',
        'app.example.org',
        '//app.example.org',
        'https://',
        'https://app.example.org?x=1',
        'https://app.example.org#top',
        'https://user@app.example.org',
        'https://app.example.org, https://admin.example.org',
        'https://app.example.org ',
        '1http://app.example.org',
        '*://app.example.org',
    }) do
        -- Негодный стоит вторым: место в отказе — настоящее, а не первое.
        t.assert_error_msg_equals(
            'настройки слоя cors.origins[2] — источник вида https://app.example.org: '
                .. ('схема и узел, без пути и косой черты в конце, а не «%s»'):format(
                    wrong
                ),
            cors,
            { origins = { APP, wrong } }
        )
    end
end

g.test_an_origin_error_blames_the_caller = function()
    assert_blamed(
        function()
            cors({ origins = { 'https://app.example.org/' } })
        end,
        'настройки слоя cors.origins[1] — источник вида https://app.example.org: '
            .. 'схема и узел, без пути и косой черты в конце, а не «https://app.example.org/»'
    )
end

-- `null` присылают песочницы и локальные файлы любого сайта.
g.test_the_null_origin_is_refused_in_any_case = function()
    for _, null in ipairs({ 'null', 'NULL' }) do
        t.assert_error_msg_equals(
            'настройки слоя cors.origins[2]: источник «null» присылают песочницы '
                .. 'и локальные файлы любого сайта — разрешить его значит разрешить всем',
            cors,
            { origins = { APP, null } }
        )
    end
end

g.test_a_star_stands_only_for_the_whole_first_label = function()
    for _, wrong in ipairs({
        'https://*.com',
        'https://*.localhost:3000',
        'https://app.*.example.org',
        'https://*example.org',
        'https://a*.example.org',
        'https://*.*.example.org',
        'https://*..org',
        'https://*.example.',
        'https://*.example.*',
        'https://*',
    }) do
        t.assert_error_msg_equals(
            'настройки слоя cors.origins[2] — звёздочка только целым первым участком узла, '
                .. ('и над ней не меньше двух участков: https://*.example.org, а не «%s»'):format(
                    wrong
                ),
            cors,
            { origins = { APP, wrong } }
        )
    end
end

g.test_any_origin_with_credentials_is_refused = function()
    assert_blamed(
        function()
            cors({ origins = { APP, '*' }, credentials = true })
        end,
        'настройки слоя cors: источник «*» вместе с credentials браузер отвергает, '
            .. 'а подставить вместо него пришедший источник — значит отдать ответы с куками посетителя '
            .. 'любому сайту; назовите источники списком'
    )
end

g.test_any_origin_without_credentials_is_built = function()
    t.assert_type(cors({ origins = { '*' } }), 'function')
    t.assert_type(cors({ origins = { '*' }, credentials = false }), 'function')
end

g.test_a_star_among_names_with_credentials_is_refused = function()
    for _, field in ipairs({ 'methods', 'headers', 'expose' }) do
        local opts = { origins = { APP }, credentials = true }

        opts[field] = { 'x-first', '*' }

        t.assert_error_msg_equals(
            ('настройки слоя cors.%s: звёздочку вместе с credentials браузер '):format(
                field
            )
                .. 'читает не как «любой», а как имя «*» — назовите имена списком',
            cors,
            opts
        )
    end

    assert_blamed(
        function()
            cors({ origins = { APP }, credentials = true, headers = { '*' } })
        end,
        'настройки слоя cors.headers: звёздочку вместе с credentials браузер '
            .. 'читает не как «любой», а как имя «*» — назовите имена списком'
    )
end

g.test_a_star_among_names_without_credentials_is_a_name_like_any_other = function()
    local answer = headers_of({ origins = { APP }, methods = { '*' }, headers = { '*' } }, preflight(APP))

    t.assert_equals(answer['access-control-allow-methods'], '*')
    t.assert_equals(answer['access-control-allow-headers'], '*')
end

g.test_a_line_of_a_list_holds_one_name = function()
    for _, field in ipairs({ 'methods', 'headers', 'expose' }) do
        for _, wrong in ipairs({ 'content-type, authorization', 'x request', 'x:y', 'x-ё' }) do
            local opts = { origins = { APP } }

            opts[field] = { 'x-first', wrong }

            t.assert_error_msg_equals(
                ('настройки слоя cors.%s[2] — одно имя без пробелов и запятых, а не «%s»'):format(
                    field,
                    wrong
                ),
                cors,
                opts
            )
        end
    end

    assert_blamed(
        function()
            cors({ origins = { APP }, expose = { 'a b' } })
        end,
        'настройки слоя cors.expose[1] — одно имя без пробелов и запятых, а не «a b»'
    )
end

g.test_a_name_may_use_every_sign_of_a_token = function()
    local name = "a1!#$%&'*+-.^_`|~"

    t.assert_equals(
        headers_of({ origins = { APP }, headers = { name } }, preflight(APP))['access-control-allow-headers'],
        name
    )
end

-- Простой запрос -------------------------------------------------------------

g.test_a_listed_origin_gets_its_permission_and_the_handler_answers = function()
    local handler, calls = counting()
    local response, err = cors({ origins = { FOREIGN, APP } })(from(APP), handler)

    t.assert_equals(err, nil)
    t.assert_equals(calls.count, 1)
    t.assert_equals(response, {
        status = 200,
        headers = {
            ['content-type'] = 'application/json',
            ['access-control-allow-origin'] = APP,
            vary = 'Origin',
        },
        body = '[]',
    })
end

g.test_a_foreign_origin_passes_without_permission = function()
    local handler, calls = counting()
    local response = cors({ origins = { APP } })(from(FOREIGN), handler)

    t.assert_equals(calls.count, 1)
    t.assert_equals(response.headers, { ['content-type'] = 'application/json', vary = 'Origin' })
end

-- Кэш по дороге не должен отдать ответ без разрешения тому, кому оно есть.
g.test_a_request_without_an_origin_still_varies_by_it = function()
    t.assert_equals(
        headers_of({ origins = { APP } }, from(nil)),
        { ['content-type'] = 'application/json', vary = 'Origin' }
    )
end

g.test_credentials_and_exposed_headers_come_with_the_permission = function()
    t.assert_equals(headers_of(everything(), from(APP)), {
        ['content-type'] = 'application/json',
        ['access-control-allow-origin'] = APP,
        ['access-control-allow-credentials'] = 'true',
        ['access-control-expose-headers'] = 'x-request-id, x-ratelimit-remaining',
        vary = 'Origin',
    })
end

-- Учётные данные и видные заголовки — часть разрешения: чужому их нет.
g.test_a_foreign_origin_gets_neither_credentials_nor_exposed_headers = function()
    t.assert_equals(headers_of(everything(), from(FOREIGN)), { ['content-type'] = 'application/json', vary = 'Origin' })
end

-- Сверяются строчными, а в ответ уходит источник как прислан: браузер
-- сверяет заголовок побайтно.
g.test_origins_are_compared_without_case_and_echoed_as_sent = function()
    local layer = cors({ origins = { 'HTTPS://App.Example.ORG', 'https://*.Example.NET' } })

    t.assert_equals(layer(from(APP), (counting())).headers['access-control-allow-origin'], APP)
    t.assert_equals(
        layer(from('https://APP.example.org'), (counting())).headers['access-control-allow-origin'],
        'https://APP.example.org'
    )
    t.assert_equals(
        layer(from('https://Api.Example.net'), (counting())).headers['access-control-allow-origin'],
        'https://Api.Example.net'
    )
end

g.test_a_subdomain_pattern_takes_subdomains_and_nothing_else = function()
    local layer = cors({ origins = { 'https://*.example.org' } })
    local cases = {
        ['https://api.example.org'] = true,
        ['https://a.b.example.org'] = true,
        ['https://a-b_c.example.org'] = true,
        ['https://example.org'] = false,
        ['https://.example.org'] = false,
        ['https://evilexample.org'] = false,
        ['https://api.exampleXorg'] = false,
        ['https://api.example.org.evil.com'] = false,
        ['http://api.example.org'] = false,
        ['https://api.example.org:8443'] = false,
        ['https://x/y.example.org'] = false,
        ['https://x:1.example.org'] = false,
        ['https://x@y.example.org'] = false,
        ['xhttps://api.example.org'] = false,
    }

    for origin, allowed in pairs(cases) do
        local header = layer(from(origin), (counting())).headers['access-control-allow-origin']

        t.assert_equals(header ~= nil, allowed, origin)
    end
end

g.test_a_subdomain_pattern_keeps_its_port = function()
    local layer = cors({ origins = { 'https://*.example.org:8443' } })

    t.assert_equals(
        layer(from('https://api.example.org:8443'), (counting())).headers['access-control-allow-origin'],
        'https://api.example.org:8443'
    )
    t.assert_equals(layer(from('https://api.example.org'), (counting())).headers['access-control-allow-origin'], nil)
    t.assert_equals(
        layer(from('https://api.example.org:84430'), (counting())).headers['access-control-allow-origin'],
        nil
    )
end

-- Схема из одной буквы — тоже схема: браузерные расширения и встроенные
-- страницы приходят со своими.
g.test_a_scheme_of_one_letter_is_a_scheme = function()
    local layer = cors({ origins = { 'x://app', 'y://*.a.b' } })

    t.assert_equals(layer(from('x://app'), (counting())).headers['access-control-allow-origin'], 'x://app')
    t.assert_equals(layer(from('y://c.a.b'), (counting())).headers['access-control-allow-origin'], 'y://c.a.b')
end

g.test_an_exact_origin_is_not_a_pattern = function()
    local layer = cors({ origins = { 'http://localhost:3000', 'http://[::1]:3000' } })

    t.assert_equals(
        layer(from('http://localhost:3000'), (counting())).headers['access-control-allow-origin'],
        'http://localhost:3000'
    )
    t.assert_equals(
        layer(from('http://[::1]:3000'), (counting())).headers['access-control-allow-origin'],
        'http://[::1]:3000'
    )
    t.assert_equals(layer(from('http://localhost:30001'), (counting())).headers['access-control-allow-origin'], nil)
    t.assert_equals(layer(from('http://localhostX3000'), (counting())).headers['access-control-allow-origin'], nil)
end

-- Источник не строкой — не источник: разрешения нет, а запрос идёт дальше.
g.test_an_origin_that_is_not_a_string_is_no_origin = function()
    local handler, calls = counting()
    local response = cors({ origins = { APP } })(request({ origin = { APP } }), handler)

    t.assert_equals(calls.count, 1)
    t.assert_equals(response.headers['access-control-allow-origin'], nil)
    t.assert_equals(response.headers.vary, 'Origin')
end

g.test_any_origin_is_answered_with_a_star_and_does_not_vary = function()
    local opts = { origins = { '*' }, expose = { 'x-request-id' } }
    local expected = {
        ['content-type'] = 'application/json',
        ['access-control-allow-origin'] = '*',
        ['access-control-expose-headers'] = 'x-request-id',
    }

    t.assert_equals(headers_of(opts, from(APP)), expected)
    t.assert_equals(headers_of(opts, from('null')), expected)
    -- Без источника тоже: кэш иначе отдал бы сохранённый ответ без
    -- разрешения межсайтовому запросу.
    t.assert_equals(headers_of(opts, from(nil)), expected)
end

-- `*` в списке покрывает всех, и соседние имена ничего не меняют.
g.test_a_star_among_origins_allows_everyone = function()
    t.assert_equals(headers_of({ origins = { APP, '*' } }, from(FOREIGN))['access-control-allow-origin'], '*')
end

g.test_without_credentials_there_is_no_credentials_header = function()
    t.assert_equals(
        headers_of({ origins = { APP }, credentials = false }, from(APP))['access-control-allow-credentials'],
        nil
    )
    t.assert_equals(
        headers_of({ origins = { APP }, credentials = false }, preflight(APP))['access-control-allow-credentials'],
        nil
    )
end

-- Межсайтовые заголовки — дело слоя: поставленное обработчиком перебивается.
g.test_the_permission_overrides_what_the_handler_set = function()
    local handler = answering({ status = 200, headers = { ['access-control-allow-origin'] = '*' } })
    local response = cors({ origins = { APP } })(from(APP), handler)

    t.assert_equals(response.headers['access-control-allow-origin'], APP)
end

-- Копии ----------------------------------------------------------------------

-- Одна и та же таблица на каждый запрос: разрешение одного источника
-- не должно уехать в ответ другому.
g.test_a_shared_response_is_copied_not_changed = function()
    local shared = { status = 200, headers = { ['content-type'] = 'text/plain' }, body = 'pong' }
    local layer = cors({ origins = { APP }, credentials = true })

    local first = layer(from(APP), answering(shared))
    local second = layer(from(FOREIGN), answering(shared))

    t.assert_not_equals(first, shared)
    t.assert_equals(shared, { status = 200, headers = { ['content-type'] = 'text/plain' }, body = 'pong' })
    t.assert_equals(first.headers['access-control-allow-origin'], APP)
    t.assert_equals(second.headers, { ['content-type'] = 'text/plain', vary = 'Origin' })
    t.assert_equals(second.body, 'pong')
end

g.test_the_copy_keeps_the_metatable = function()
    local kind = { __index = { kind = 'ответ' } }
    local response = setmetatable({ status = 200 }, kind)
    local copied = cors({ origins = { APP } })(from(APP), answering(response))

    t.assert_equals(getmetatable(copied), kind)
    t.assert_equals(copied.kind, 'ответ')
end

-- Закрытая метатаблица тоже доезжает до копии, а не её заглушка.
g.test_the_copy_keeps_a_protected_metatable = function()
    local kind = { __metatable = 'закрыто', __index = { kind = 'ответ' } }
    local copied = cors({ origins = { APP } })(from(APP), answering(setmetatable({ status = 200 }, kind)))

    t.assert_equals(copied.kind, 'ответ')
    t.assert_equals(getmetatable(copied), 'закрыто')
end

g.test_a_response_without_headers_gets_them = function()
    local response = cors({ origins = { APP } })(from(APP), answering({ status = 204 }))

    t.assert_equals(response, { status = 204, headers = { ['access-control-allow-origin'] = APP, vary = 'Origin' } })
end

-- Ставить некуда: ответ уходит как был, и спотыкается о него сервер, а не слой.
g.test_a_response_with_headers_that_are_not_a_table_is_left_as_it_is = function()
    local response = { status = 200, headers = 'content-type: text/plain' }

    t.assert_is(cors({ origins = { APP } })(from(APP), answering(response)), response)
end

g.test_a_response_that_is_not_a_table_is_left_as_it_is = function()
    t.assert_equals(cors({ origins = { APP } })(from(APP), answering('готово')), 'готово')
end

-- Отказ снизу ------------------------------------------------------------------

g.test_a_refusal_from_below_gets_the_permission_in_its_headers = function()
    local kind = {
        __tostring = function(refusal)
            return refusal.message
        end,
    }
    local refusal = setmetatable({
        status = 429,
        message = 'слишком много запросов',
        headers = { ['retry-after'] = '30' },
    }, kind)

    local response, err = cors(everything())(from(APP), answering(nil, refusal))

    t.assert_equals(response, nil)
    t.assert_not_equals(err, refusal)
    t.assert_equals(getmetatable(err), kind)
    t.assert_equals(tostring(err), 'слишком много запросов')
    t.assert_equals(err.status, 429)
    t.assert_equals(err.headers, {
        ['retry-after'] = '30',
        ['access-control-allow-origin'] = APP,
        ['access-control-allow-credentials'] = 'true',
        ['access-control-expose-headers'] = 'x-request-id, x-ratelimit-remaining',
        vary = 'Origin',
    })
    -- Исходный отказ не тронут: его вправе отдавать не один раз.
    t.assert_equals(refusal.headers, { ['retry-after'] = '30' })
end

g.test_a_refusal_to_a_foreign_origin_only_varies = function()
    local _, err = cors({ origins = { APP } })(from(FOREIGN), answering(nil, { status = 403 }))

    t.assert_equals(err, { status = 403, headers = { vary = 'Origin' } })
end

-- Только отказ по договору границы HTTP: у прочего заголовкам не место.
g.test_a_refusal_without_a_numeric_status_is_left_as_it_is = function()
    local layer = cors({ origins = { APP } })

    for _, refusal in ipairs({ { status = '403' }, { message = 'нет' } }) do
        local _, err = layer(from(APP), answering(nil, refusal))

        t.assert_is(err, refusal)
    end

    t.assert_equals(
        select(2, layer(from(APP), answering(nil, 'хранилище молчит'))),
        'хранилище молчит'
    )
end

-- Vary ------------------------------------------------------------------------

g.test_origin_is_added_to_vary_once = function()
    local layer = cors({ origins = { APP } })
    local cases = {
        { given = 'Accept-Encoding', expected = 'Accept-Encoding, Origin' },
        { given = 'accept-encoding, origin', expected = 'accept-encoding, origin' },
        { given = 'Accept-Encoding,  ORIGIN ', expected = 'Accept-Encoding,  ORIGIN ' },
        { given = ' Origin', expected = ' Origin' },
        { given = 'X-Origin-Id', expected = 'X-Origin-Id, Origin' },
        { given = '*', expected = '*' },
        { given = '', expected = 'Origin' },
    }

    for _, case in ipairs(cases) do
        local response = layer(from(APP), answering({ status = 200, headers = { vary = case.given } }))

        t.assert_equals(response.headers.vary, case.expected, case.given)
    end
end

-- Значение списком слой не разбирает.
g.test_vary_that_is_not_a_string_is_left_as_it_is = function()
    local list = { 'Accept-Encoding' }
    local response = cors({ origins = { APP } })(from(APP), answering({ status = 200, headers = { vary = list } }))

    t.assert_is(response.headers.vary, list)
end

-- Предварительный запрос --------------------------------------------------------

g.test_a_preflight_is_answered_by_the_layer_without_the_handler = function()
    local handler, calls = counting()
    local response, err = cors(everything())(preflight(APP), handler)

    t.assert_equals(err, nil)
    t.assert_equals(calls.count, 0)
    t.assert_equals(response, {
        status = 204,
        headers = {
            ['access-control-allow-origin'] = APP,
            ['access-control-allow-credentials'] = 'true',
            ['access-control-allow-methods'] = 'PUT, DELETE',
            ['access-control-allow-headers'] = 'content-type, authorization',
            ['access-control-max-age'] = '600',
            vary = 'Origin',
        },
    })
end

-- Без названного — ничего сверх разрешения: браузер тогда пустит только
-- способы и заголовки, которые шлёт без спроса.
g.test_a_preflight_names_only_what_was_allowed = function()
    local response = cors({ origins = { APP } })(preflight(APP), (counting()))

    t.assert_equals(response, {
        status = 204,
        headers = { ['access-control-allow-origin'] = APP, vary = 'Origin' },
    })
end

g.test_one_method_and_one_header_are_named_too = function()
    local answer = headers_of({ origins = { APP }, methods = { 'patch' }, headers = { 'X-Token' } }, preflight(APP))

    t.assert_equals(answer['access-control-allow-methods'], 'PATCH')
    t.assert_equals(answer['access-control-allow-headers'], 'x-token')
end

g.test_a_preflight_from_a_foreign_origin_is_refused_without_the_handler = function()
    local handler, calls = counting()
    local response, err = cors(everything())(preflight(FOREIGN), handler)

    t.assert_equals(response, nil)
    t.assert_equals(calls.count, 0)
    t.assert_equals(err.status, 403)
    t.assert_equals(err.message, 'источник запроса не разрешён')
    t.assert_equals(err.code, 'cors_origin_denied')
    t.assert_equals(err.reason, ('источник «%s» не в списке разрешённых'):format(FOREIGN))
    t.assert_equals(err.headers, { vary = 'Origin' })
    t.assert_equals(
        tostring(err),
        ('источник запроса не разрешён: источник «%s» не в списке разрешённых'):format(
            FOREIGN
        )
    )
end

g.test_the_refusal_is_named_by_the_constants_of_the_layer = function()
    local layer = helper.part('tnt.middleware.layer.cors')

    t.assert_equals(
        { layer.STATUS, layer.MESSAGE, layer.CODE, layer.PREFLIGHT_STATUS, layer.VARY },
        { 403, 'источник запроса не разрешён', 'cors_origin_denied', 204, 'Origin' }
    )
end

g.test_any_origin_answers_every_preflight_with_a_star = function()
    local response = cors({ origins = { '*' }, methods = { 'PUT' } })(preflight(FOREIGN), (counting()))

    t.assert_equals(response, {
        status = 204,
        headers = { ['access-control-allow-origin'] = '*', ['access-control-allow-methods'] = 'PUT' },
    })
end

-- `OPTIONS` без источника или без спрошенного способа — обычный запрос:
-- отвечать на него роутеру.
g.test_options_without_the_signs_of_a_preflight_goes_to_the_handler = function()
    local layer = cors({ origins = { APP } })

    for _, context in ipairs({
        request({ origin = APP }, 'OPTIONS'),
        request({ ['access-control-request-method'] = 'PUT' }, 'OPTIONS'),
        request({ origin = APP, ['access-control-request-method'] = 'PUT' }, 'POST'),
    }) do
        local handler, calls = counting()
        local response = layer(context, handler)

        t.assert_equals(calls.count, 1)
        t.assert_equals(response.status, 200)
    end
end

-- Не HTTP ----------------------------------------------------------------------

g.test_a_context_without_headers_goes_by_untouched = function()
    local layer = cors({ origins = { APP } })
    local answer = { status = 200 }

    for _, context in ipairs({ 'сообщение', { method = 'GET', path = '/api' }, { headers = 'origin: x' } }) do
        local seen
        local response = layer(context, function(given)
            seen = given

            return answer
        end)

        t.assert_is(seen, context)
        t.assert_is(response, answer)
    end
end

-- Реестр ------------------------------------------------------------------------

g.test_the_layer_takes_the_tag_of_the_registry_and_its_filter = function()
    local chain = g.middleware.new({ tag = 'app.http' }):chain({ { 'cors', { origins = { APP } }, path = '/api' } })
    local inside = chain:run(from(APP), (counting()))
    local outside = chain:run({ method = 'GET', path = '/panel', headers = { origin = APP } }, (counting()))

    t.assert_equals(inside.headers['access-control-allow-origin'], APP)
    t.assert_equals(outside.headers, { ['content-type'] = 'application/json' })
end

g.test_the_layer_by_name_without_settings_is_refused = function()
    t.assert_error_msg_contains('настройки слоя cors.origins — массив, а не nil', function()
        g.middleware.chain({ 'cors' })
    end)
end

g.test_a_refusal_of_the_preflight_goes_up_the_chain_as_a_refusal = function()
    local response, err =
        g.middleware.chain({ 'log', { 'cors', { origins = { APP } } } }):run(preflight(FOREIGN), (counting()))

    t.assert_equals(response, nil)
    t.assert_equals(err.status, 403)
    t.assert_equals(g.logged('запрос не прошёл'), true)
end
