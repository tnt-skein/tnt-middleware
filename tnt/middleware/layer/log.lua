--- Слой журнала: запись о каждом проходе конвейера.
---
--- Запись пишется на выходе, а не на входе: до обработчика ещё неизвестно
--- ни чем кончилось дело, ни сколько оно заняло, а две записи на запрос —
--- это вдвое больше журнала ради одной строки смысла. Запрос, который
--- не вернулся вовсе, виден иначе: по отсутствию записи о нём.
---
--- Отказ здесь не гасится: слой рассказывает о нём и отдаёт дальше
--- нетронутым. Гасит отказ слой перехвата, и решать это должен он один.
---
--- Код ответа слой берёт из самого ответа — из поля `status` таблицы.
--- Больше о виде ответа журнал не знает ничего: запись о запросе
--- без кода ответа — это строка доступа, по которой не понять, чем
--- запрос кончился, а описатель из настроек видит только запрос — ответа
--- у него нет. Ответ не таблицей и таблица без `status` кода в записи
--- не дают: очередь или клиент, у которых ответ устроен иначе, пишут
--- своё описателем.

local common = require('tnt.middleware.layer.common')

local Module = {}

---@class TntMiddlewareLogOptions
---@field tag string|nil Метка журнала
---@field level string|nil Уровень удачного прохода; по умолчанию info
---@field describe (fun(context: any): table|nil)|nil Чем описать запрос

--- Собирает слой журнала.
---@param opts TntMiddlewareLogOptions|nil
---@return TntMiddlewareFn
function Module.new(opts)
    local options = opts or {}
    local level = options.level or 'info'

    common.callable(options.describe, 'описатель запроса — функция (context) -> поля')

    local journal = common.journal(options)

    -- Уровни спрашиваются у самого журнала, а не перечисляются здесь:
    -- перечисление однажды разойдётся с ним, и слой станет отвергать
    -- уровень, который журнал понимает.
    if journal[level] == nil then
        -- Уровень 2 винит того, кто собрал слой, а не эту строку. Реестр
        -- зовёт фабрику под `pcall`, у кадра `pcall` строки нет, и место —
        -- строку объявления цепочки — приписывает вход реестра.
        error(('журналу неизвестен уровень «%s»'):format(tostring(level)), 2)
    end

    return function(context, next_layer)
        local response, err, seconds = common.timed(function()
            return next_layer(context)
        end)

        -- Под pcall — только описатель: он приходит от приложения и бросить
        -- вправе. Сама запись идёт вне pcall, прямо из этой функции: так
        -- журнал ядра называет местом записи строку слоя.
        local described, fields = pcall(common.fields_of, options, context)

        if not described then
            common.failed(journal, 'записать о запросе', fields)

            return response, err
        end

        fields.seconds = seconds

        if err == nil then
            -- Код ответа — только из таблицы: у строки и у пустоты его нет,
            -- а поле без значения в записи и так не появится.
            if type(response) == 'table' then
                fields.status = response.status
            end

            journal[level]('запрос прошёл', fields)

            return response, err
        end

        -- Отказ — предупреждение, а не ошибка: клиент, ушедший
        -- с отказом, — беда клиента; ошибкой зовётся то, что сорвалось
        -- у нас, и об этом пишет слой перехвата.
        fields.err = err
        journal.warn('запрос не прошёл', fields)

        return response, err
    end
end

return Module
