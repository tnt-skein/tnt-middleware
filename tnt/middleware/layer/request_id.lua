--- Слой опознавателя: у каждого запроса своё имя.
---
--- Без опознавателя записи журнала об одном запросе не собрать: на узле
--- их сотни в секунду, и «запрос не прошёл» без имени не связать
--- ни с входом, ни с ответом.
---
--- Пришедший опознаватель важнее своего: запрос, прошедший через
--- несколько узлов, обязан оставаться одним запросом, иначе след
--- обрывается на первой же границе. Откуда его брать — знает вызывающий:
--- в HTTP это заголовок, в очереди — поле сообщения, и конвейеру эта
--- разница неизвестна. Но пришедшее — недоверенный вход: опознаватель,
--- не прошедший правило ключа контекста (`context.check`) — длиннее
--- предела, с управляющим знаком, не строка, — заменяется своим, а не
--- роняет запрос и не уезжает в журнал и в заголовок ответа как есть.
---
--- Опознаватель кладётся в два места, и это нарочно. В поле запроса —
--- его читает слой `request_id_header`, чтобы вернуть клиенту. В контекст
--- файбера (`tnt-context`) — оттуда его берёт журнал в каждую запись
--- остатка цепочки, и оттуда же он уезжает с исходящими обращениями.
--- Остаток цепочки идёт внутри области `context.run`, и по выходе, в любом
--- исходе, контекст прежний: файбер соединения `http.server` обслуживает
--- все запросы keep-alive, и без этого второй запрос унёс бы опознаватель
--- первого.
---
--- Слой стоит первым: всё, что ниже, пишет журнал уже с опознавателем.

local context = require('tnt.context')

local common = require('tnt.middleware.layer.common')

local Module = {}

---@class TntMiddlewareRequestIdOptions
---@field field string|nil Поле запроса для опознавателя
---@field take (fun(request: any): string|nil)|nil Откуда взять пришедший
---@field generate (fun(): string)|nil Чем выдавать свой

--- Собирает слой опознавателя.
---@param opts TntMiddlewareRequestIdOptions|nil
---@return TntMiddlewareFn
function Module.new(opts)
    local options = opts or {}
    local field = options.field or common.REQUEST_FIELD

    -- Обе настройки зовутся вне aside и на каждом запросе: не-функция
    -- здесь превратила бы в отказ всякий проход, и обнаружилось бы это
    -- в бою. Поэтому спрашивается при сборке слоя — когда отвечать
    -- ещё некому.
    common.callable(options.take, 'откуда взять опознаватель — функция (context)')
    common.callable(options.generate, 'выдача опознавателей — функция () -> имя')

    local take = options.take
    local generate = options.generate or common.identifier

    return function(request, next_layer)
        if type(request) ~= 'table' then
            -- Класть опознаватель некуда, и молчать об этом нельзя:
            -- журнал остался бы без опознавателей, а причина — неизвестной.
            return nil,
                'опознаватель запроса некуда положить: контекст не таблица'
        end

        local given = request[field]

        if given == nil and take ~= nil then
            given = take(request)
        end

        -- Негодное пришедшее — не отказ, а повод выдать своё: клиент,
        -- приславший мусор в заголовке, получает ответ, а журнал —
        -- опознаватель, который можно назвать вслух.
        if given ~= nil and not context.check(context.REQUEST_ID, given) then
            given = nil
        end

        local identifier = given or generate()

        request[field] = identifier

        return context.run({ [context.REQUEST_ID] = identifier }, next_layer, request)
    end
end

return Module
