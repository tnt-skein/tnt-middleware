--- Слой опознавателя в ответе: номер, который можно назвать вслух.
---
--- Опознаватель, известный одному журналу, полезен наполовину. Человек,
--- у которого не вышло, звонит и не может назвать ничего, а дежурный
--- ищет его запрос по времени и пути среди тысяч соседних. Опознаватель
--- в ответе делает разговор коротким: номер называют, и по нему находится
--- ровно одна цепочка записей.
---
--- Слой `request_id` кладёт опознаватель в контекст — этого довольно
--- журналу и нечего клиенту. Дописывать заголовок в каждом приложении
--- руками — то же самое, что писать в каждом обработчике запись
--- в журнал: однажды забудется, и забудется там, где нужнее всего.
---
--- Заголовок ставится без спроса, а вот пришедший опознаватель слой
--- `request_id` без спроса не берёт. Асимметрия нарочная: свой ответ мы
--- правим у себя дома, а заголовок запроса пишет клиент, и верить ему
--- на слово — решение приложения, а не конвейера.
---
--- Ставить слой надо выше перехвата: ответ об отказе собирает перехват,
--- а на выходе цепочка идёт снизу вверх, и стоящий выше видит уже
--- собранный ответ. Стоящий ниже увидел бы только отказ, которому
--- заголовок ставить некуда.

local common = require('tnt.middleware.layer.common')

local Module = {}

---@class TntMiddlewareRequestIdHeaderOptions
---@field tag string|nil Метка журнала
---@field field string|nil Поле контекста с опознавателем
---@field header string|nil Имя заголовка ответа
---@field put (fun(response: any, id: string))|nil Куда класть, если ответ не HTTP

--- Кладёт опознаватель заголовком ответа.
---@param header string
---@return fun(response: table, id: string)
local function into_header(header)
    return function(response, id)
        -- Заголовков у ответа может не быть вовсе: обработчик, вернувший
        -- только статус и тело, — обычное дело, и заводить их приходится
        -- самому.
        local headers = response.headers or {}

        -- Своё имя перебивает чужое намеренно. Обработчик, поставивший
        -- сюда другой номер, развёл бы журнал и ответ: человек назвал бы
        -- один номер, а искать пришлось бы по другому — а это ровно
        -- то, ради чего слой и заведён.
        headers[header] = id
        response.headers = headers
    end
end

--- Собирает слой опознавателя в ответе.
---@param opts TntMiddlewareRequestIdHeaderOptions|nil
---@return TntMiddlewareFn
function Module.new(opts)
    local options = opts or {}
    local field = options.field or common.REQUEST_FIELD

    common.callable(options.put, 'укладчик опознавателя — функция (response, id)')

    local put = options.put or into_header(options.header or common.REQUEST_HEADER)
    local journal = common.journal(options)

    return function(context, next_layer)
        local response, err = next_layer(context)
        local id

        if type(context) == 'table' then
            id = context[field]
        end

        -- Класть нечего или некуда: цепочка без слоя опознавателя, ответ
        -- строкой, отказ вместо ответа. Отказать здесь было бы хуже
        -- пропущенного заголовка: запрос отработал, и терять его ответ
        -- из-за ненаписанного номера незачем.
        if id ~= nil and type(response) == 'table' then
            -- И по той же причине укладчик идёт через aside: он приходит
            -- от приложения, а встроенный спотыкается о заголовки,
            -- оказавшиеся не таблицей. Ответ к этому мигу уже собран,
            -- и исключение отсюда унесло бы именно его.
            common.aside(journal, 'положить опознаватель в ответ', function()
                put(response, id)
            end)
        end

        return response, err
    end
end

return Module
