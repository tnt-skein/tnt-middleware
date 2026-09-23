--- Живой узел: межсайтовые заголовки по сети.
---
--- Сервер — настоящий `http.server` в том же процессе, на случайном порту;
--- запросы шлёт `http.client` с теми заголовками, что шлёт браузер. Проверка
--- видит то же, что браузер: имена и значения заголовков на проводе, код
--- ответа на предварительный запрос и то, что до обработчика он не дошёл.
--- Докер для этого не нужен, и гейт от него не зависит.

local t = require('luatest')

local http_client = require('http.client')
local http_server = require('http.server')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware.layer.cors.server')

--- Свой источник и чужой.
local APP = 'https://app.example.org'
local FOREIGN = 'https://evil.example.com'

--- Сколько раз обработчик позвали на этом сервере.
local handled = 0

---@type table|nil
local httpd

--- Адрес поднятого сервера.
---@type string
local address

--- Обработчик: отвечает телом, а по пути `/api/limited` отказывает,
--- как предел частоты, — парой с заголовком повтора.
---@param request table
---@return table|nil
---@return table|nil
local function handler(request)
    handled = handled + 1

    if request.path == '/api/limited' then
        return nil,
            {
                status = 429,
                message = 'слишком много запросов',
                headers = { ['retry-after'] = '30' },
            }
    end

    return { status = 200, headers = { ['content-type'] = 'application/json' }, body = '{"customers":[]}' }
end

--- Поднимает сервер с цепочкой вокруг обработчика.
---
--- Запрос приводится к договору роутера — способ, путь, заголовки
--- с именами строчными, — а отказ рисуется так, как его рисует обработчик
--- отказов на границе: код и заголовки из самого отказа, слово телом.
---@param entries any Записи цепочки
local function serving(entries)
    local wrapped = g.middleware.chain(entries):wrap(handler)

    httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })
    httpd.options.handler = function(_, incoming)
        local response, err = wrapped({ method = incoming.method, path = incoming.path, headers = incoming.headers })

        if response == nil then
            return { status = err.status, headers = err.headers, body = err.message }
        end

        return response
    end
    httpd:start()

    address = ('http://127.0.0.1:%d'):format(httpd.tcp_server:name().port)
end

--- Запрос по сети.
---@param method string
---@param path string
---@param headers table
---@return table
local function asked(method, path, headers)
    return http_client.new():request(method, address .. path, nil, { timeout = 5, headers = headers })
end

--- Предварительный запрос браузера перед `PUT` с телом JSON.
---@param origin string
---@return table
local function preflight(origin)
    return asked('OPTIONS', '/api/customers/7', {
        origin = origin,
        ['access-control-request-method'] = 'PUT',
        ['access-control-request-headers'] = 'content-type',
    })
end

g.before_each(function()
    handled = 0

    serving({
        {
            'cors',
            {
                origins = { APP },
                methods = { 'PUT', 'DELETE' },
                headers = { 'content-type' },
                expose = { 'retry-after' },
                max_age = 600,
                credentials = true,
            },
            path = '/api',
        },
    })
end)

g.after_each(function()
    if httpd ~= nil then
        httpd:stop()
        httpd = nil
    end
end)

g.test_a_simple_request_from_a_listed_origin_is_read_by_the_page = function()
    local response = asked('GET', '/api/customers', { origin = APP })

    t.assert_equals(response.status, 200)
    t.assert_equals(response.body, '{"customers":[]}')
    t.assert_equals(response.headers['access-control-allow-origin'], APP)
    t.assert_equals(response.headers['access-control-allow-credentials'], 'true')
    t.assert_equals(response.headers['access-control-expose-headers'], 'retry-after')
    t.assert_equals(response.headers.vary, 'Origin')
    t.assert_equals(handled, 1)
end

-- Запрос доходит до обработчика и без разрешения: межсайтовые заголовки —
-- не запрет узлу, а разрешение браузеру показать ответ сценарию.
g.test_a_simple_request_from_a_foreign_origin_goes_without_permission = function()
    local response = asked('GET', '/api/customers', { origin = FOREIGN })

    t.assert_equals(response.status, 200)
    t.assert_equals(response.body, '{"customers":[]}')
    t.assert_equals(response.headers['access-control-allow-origin'], nil)
    t.assert_equals(response.headers['access-control-allow-credentials'], nil)
    t.assert_equals(response.headers.vary, 'Origin')
    t.assert_equals(handled, 1)
end

g.test_a_preflight_from_a_listed_origin_is_answered_without_the_handler = function()
    local response = preflight(APP)

    t.assert_equals(response.status, 204)
    t.assert_equals(response.headers['access-control-allow-origin'], APP)
    t.assert_equals(response.headers['access-control-allow-methods'], 'PUT, DELETE')
    t.assert_equals(response.headers['access-control-allow-headers'], 'content-type')
    t.assert_equals(response.headers['access-control-max-age'], '600')
    t.assert_equals(response.headers['access-control-allow-credentials'], 'true')
    t.assert_equals(response.headers.vary, 'Origin')
    t.assert_equals(handled, 0)
end

g.test_a_preflight_from_a_foreign_origin_is_refused_without_the_handler = function()
    local response = preflight(FOREIGN)

    t.assert_equals(response.status, 403)
    t.assert_equals(response.body, 'источник запроса не разрешён')
    t.assert_equals(response.headers['access-control-allow-origin'], nil)
    t.assert_equals(response.headers['access-control-allow-methods'], nil)
    t.assert_equals(response.headers.vary, 'Origin')
    t.assert_equals(handled, 0)
end

-- Сценарий читает и отказ: без разрешения на нём он увидел бы сетевую
-- ошибку вместо кода 429 и срока повтора.
g.test_a_refusal_carries_the_permission_to_the_page = function()
    local response = asked('GET', '/api/limited', { origin = APP })

    t.assert_equals(response.status, 429)
    t.assert_equals(response.headers['retry-after'], '30')
    t.assert_equals(response.headers['access-control-allow-origin'], APP)
    t.assert_equals(response.headers['access-control-expose-headers'], 'retry-after')
end

-- Мимо фильтра слоя — мимо слоя: панель под своим путём разрешений не получает.
g.test_a_path_outside_the_filter_gets_nothing = function()
    local response = asked('GET', '/panel', { origin = APP })

    t.assert_equals(response.status, 200)
    t.assert_equals(response.headers['access-control-allow-origin'], nil)
    t.assert_equals(response.headers.vary, nil)
end

g.test_any_origin_with_credentials_is_refused_by_the_settings = function()
    t.assert_error_msg_contains(
        'источник «*» вместе с credentials браузер отвергает',
        function()
            g.middleware.chain({ { 'cors', { origins = { '*' }, credentials = true } } })
        end
    )
end
