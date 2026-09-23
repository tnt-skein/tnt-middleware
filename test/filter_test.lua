--- Проверки фильтра слоя: по пути и способу, и как он пишется в записи.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.middleware.filter')

--- Модуль фильтра, загруженный группой из исходников.
---@return table
local function filter()
    return helper.part('tnt.middleware.filter')
end

--- Фильтр из полей записи; пустоты здесь быть не должно.
---@param fields table
---@return TntMiddlewareOnly
local function only(fields)
    local built = filter().of(fields)

    t.assert_type(built, 'function', 'фильтр не собрался')

    return built --[[@as TntMiddlewareOnly]]
end

g.test_record_without_filter_fields_gives_no_filter = function()
    t.assert_equals(filter().of({}), nil)
    t.assert_equals(filter().of({ name = 'журнал' }), nil)
end

g.test_path_is_a_beginning_of_the_request_path_by_segments = function()
    local api = only({ path = '/api' })

    t.assert_equals(api({ path = '/api' }), true, 'сам путь')
    t.assert_equals(api({ path = '/api/' }), true)
    t.assert_equals(api({ path = '/api/customers/7' }), true, 'всё под ним')
    t.assert_equals(api({ path = '/apix' }), false, 'участок целиком, а не знаки')
    t.assert_equals(api({ path = '/docs/api' }), false, 'начало, а не вхождение')
    t.assert_equals(api({ path = '/ap' }), false)

    -- Косая черта в конце значит то же самое: сам путь и всё под ним.
    t.assert_equals(only({ path = '/api/' })({ path = '/api' }), true)
    t.assert_equals(only({ path = '/api/' })({ path = '/api/customers' }), true)
    t.assert_equals(only({ path = '/api/' })({ path = '/apix' }), false)

    -- Корень — начало всего.
    t.assert_equals(only({ path = '/' })({ path = '/' }), true)
    t.assert_equals(only({ path = '/' })({ path = '/anything' }), true)

    -- Точка и процент в пути — знаки пути, а не образца.
    t.assert_equals(only({ path = '/v1.0' })({ path = '/v1.0/x' }), true)
    t.assert_equals(only({ path = '/v1.0' })({ path = '/v1x0/x' }), false)
    t.assert_equals(only({ path = '/%D0%B0' })({ path = '/%D0%B0/x' }), true)
end

g.test_method_is_one_name_or_a_list_and_is_compared_regardless_of_case = function()
    local writes = only({ method = { 'post', 'PUT' } })

    t.assert_equals(writes({ method = 'POST' }), true)
    t.assert_equals(writes({ method = 'put' }), true)
    t.assert_equals(writes({ method = 'GET' }), false)
    t.assert_equals(only({ method = 'get' })({ method = 'GET' }), true)
    t.assert_equals(only({ method = 'GET' })({ method = 'HEAD' }), false, 'HEAD — не GET')
end

g.test_path_and_method_together_are_both_required = function()
    local api_writes = only({ path = '/api', method = 'POST' })

    t.assert_equals(api_writes({ path = '/api/customers', method = 'POST' }), true)
    t.assert_equals(api_writes({ path = '/api/customers', method = 'GET' }), false)
    t.assert_equals(api_writes({ path = '/panel', method = 'POST' }), false)
end

g.test_request_without_path_or_method_does_not_pass_the_filter = function()
    -- Слой «только под /api» на запрос без пути ставить не просили:
    -- сообщение очереди, строка, пустота — всё мимо.
    local api = only({ path = '/api' })

    t.assert_equals(api({ method = 'GET' }), false)
    t.assert_equals(api({ path = 7 }), false)
    t.assert_equals(api('/api/customers'), false)
    t.assert_equals(api(nil), false)

    local posts = only({ method = 'POST' })

    t.assert_equals(posts({ path = '/api/customers' }), false)
    t.assert_equals(posts({ method = 7 }), false)
end

g.test_path_must_be_a_string_that_starts_with_a_slash = function()
    for _, path in ipairs({ '', 'api', 7, true, {} }) do
        t.assert_error_msg_contains(
            'путь в фильтре слоя — начало пути с косой черты, а не «',
            function()
                filter().of({ path = path })
            end
        )
    end
end

g.test_empty_segment_in_the_path_is_refused = function()
    for _, path in ipairs({ '//', '/api//', '/api//x', '//api' }) do
        t.assert_error_msg_contains(
            ('путь в фильтре слоя — начало пути по участкам, а в «%s» пустой участок'):format(
                path
            ),
            function()
                filter().of({ path = path })
            end
        )
    end
end

g.test_pattern_written_instead_of_a_path_is_refused_and_told_the_difference = function()
    -- `'/api/.*'` — привычка от рока http; как начало пути такой фильтр
    -- не прошёл бы никто, и слой стоял бы в цепочке мёртвым.
    for _, path in ipairs({ '/api/.*', '/api?', '^/api', '/api$' }) do
        t.assert_error_msg_contains(
            ('путь в фильтре слоя — начало пути, а не образец: «%s»; `/api` накрывает `/api` и всё под ним'):format(
                path
            ),
            function()
                filter().of({ path = path })
            end
        )
    end
end

g.test_method_must_be_a_name_or_a_non_empty_list_of_names = function()
    for _, method in ipairs({ 7, true, {} }) do
        t.assert_error_msg_contains(
            'способ в фильтре слоя — имя или непустой список имён, а не «',
            function()
                filter().of({ method = method })
            end
        )
    end

    for _, name in ipairs({ '', 7 }) do
        t.assert_error_msg_contains(
            ('способ в фильтре слоя — непустая строка, а не «%s»'):format(
                tostring(name)
            ),
            function()
                filter().of({ method = { 'GET', name } })
            end
        )
    end
end

g.test_both_filters_are_required_together_and_one_alone_is_itself = function()
    local api = only({ path = '/api' })
    local posts = only({ method = 'POST' })

    t.assert_is(filter().both(nil, api), api)

    local api_posts = filter().both(api, posts)

    t.assert_equals(api_posts({ path = '/api/x', method = 'POST' }), true)
    t.assert_equals(api_posts({ path = '/api/x', method = 'GET' }), false)
    t.assert_equals(api_posts({ path = '/panel', method = 'POST' }), false)
end

g.test_fields_of_the_filter_are_named_for_the_registry = function()
    t.assert_equals(filter().FIELDS, { 'path', 'method' })
end
