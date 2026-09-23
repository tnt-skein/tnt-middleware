--- Слой времени ответа: сколько занял проход.
---
--- Меряется всё, что ниже по цепочке, вместе с обработчиком: время,
--- которое видит клиент, — это не время обработчика, а время конвейера,
--- и разница между ними и есть цена слоёв.
---
--- Приёмник замера задаётся настройкой, а не берётся из пакета метрик:
--- конвейер не должен знать, куда в этом приложении складывают числа.
--- Замер, кроме того, кладётся в сам контекст — слоям выше и ответу
--- он нужен чаще, чем кажется: заголовок со временем ответа берётся
--- именно оттуда.

local common = require('tnt.middleware.layer.common')

local Module = {}

--- Поле контекста, в которое попадает длительность.
local DEFAULT_FIELD = 'duration'

---@class TntMiddlewareTimingOptions
---@field tag string|nil Метка журнала
---@field field string|nil Поле контекста для длительности
---@field observe (fun(seconds: number, context: any, err: any))|nil Куда отдать замер

--- Собирает слой времени ответа.
---@param opts TntMiddlewareTimingOptions|nil
---@return TntMiddlewareFn
function Module.new(opts)
    local options = opts or {}
    local observe = options.observe

    common.callable(observe, 'приёмник замера — функция (seconds, context, err)')

    local field = options.field or DEFAULT_FIELD
    local journal = common.journal(options)

    return function(context, next_layer)
        local response, err, seconds = common.timed(function()
            return next_layer(context)
        end)

        if type(context) == 'table' then
            context[field] = seconds
        end

        if observe ~= nil then
            common.aside(journal, 'отдать замер времени запроса', function()
                observe(seconds, context, err)
            end)
        end

        return response, err
    end
end

return Module
