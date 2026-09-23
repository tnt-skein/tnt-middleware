--- Конвейер слоёв обработки: один механизм для входящего запроса
--- и для исходящего.
---
--- Слой — функция `(context, next)`. Всё, что он делает до `next`,
--- случается на входе; всё, что после, — на выходе; а не позвав `next`,
--- слой отвечает сам и запрос дальше не идёт. Из этого и берётся порядок:
--- на входе слои проходятся сверху вниз, на выходе — снизу вверх.
---
---     middleware.chain({ 'request_id', 'rescue', 'log' })
---
---     request_id ─┐                              ┌─ request_id
---                 └─ rescue ─┐        ┌─ rescue ─┘
---                            └─ log ─ обработчик
---
--- Пользоваться так:
---
---     local middleware = require('tnt.middleware')
---
---     middleware.configure({
---         tag = 'app.http',
---         layers = {
---             -- Слой объявляется фабрикой: у одного слоя бывает
---             -- две настройки — своим шестьдесят, чужим шестьсот.
---             throttle = function(options)
---                 return function(context, next)
---                     if counted(context) > options.per_minute then
---                         return { status = 429 }
---                     end
---
---                     return next(context)
---                 end
---             end,
---         },
---         groups = { web = { 'request_id', 'rescue', 'log' } },
---     })
---
---     local chain = middleware.chain({ 'web', { 'throttle', { per_minute = 60 } } })
---     local handle = chain:wrap(function(request)
---         return { status = 200, body = 'привет' }
---     end)
---
---     local response, err = handle({ method = 'GET', path = '/customers/7' })
---
--- Тот же конвейер годится исходящему запросу: обработчик — отправка,
--- а слои вокруг неё ставят заголовки, повторяют и пишут след.
---
---     local send = middleware.chain({ 'timing', signature_layer }):wrap(function(request)
---         return http_client_send(request)
---     end)
---
--- Повтор — такой же слой: он зовёт `next` заново, пока не получит ответ.
--- Своего слоя повтора здесь нет нарочно: отступы между попытками,
--- приговор, какой отказ стоит повторять, и размыкатель — отдельное
--- ремесло со своими настройками, а конвейеру довольно того, что `next`
--- можно позвать не один раз:
---
---     local retrying = function(request, next)
---         local response, err
---
---         for _ = 1, 3 do
---             response, err = next(request)
---
---             if err == nil then
---                 return response
---             end
---         end
---
---         return response, err
---     end
---
--- Решения, о которых стоит знать заранее.
---
--- Контекст конвейеру непрозрачен. Он не знает, HTTP это или очередь,
--- и ничего в контексте не ищет: вид запроса и ответа — договор роутера
--- и клиента, а не конвейера. Готовые слои общего назначения трогают
--- контекст только там, где им это разрешили настройкой. Слой `cors` —
--- исключение по самой своей сути: межсайтовые заголовки бывают только
--- у HTTP, и он читает способ и заголовки запроса по договору роутера,
--- а запрос без заголовков пропускает нетронутым.
---
--- Цепочка не бросает исключений и не возвращает пустоты. Упавший слой
--- становится отказом — парой `nil, err`, — и слои выше видят его как
--- обычный отказ: их выход всё равно случится. Отказ упавшего шага несёт
--- стек места броска (`tnt.middleware.fall`): печатается он прежним
--- словом, а стек отдаёт полем `traceback` тому, кто его спросит. Слой,
--- не вернувший ничего, тоже становится отказом, и отказ этот называет
--- слой по имени: забытый `return next(context)` — самая частая ошибка
--- в конвейерах.
---
--- Чужой слой можно убрать, а свой поставить в нужное место: у слоёв есть
--- имена, а у цепочки — `before`, `after` и `without`. Приложение, которому
--- мешает общий слой журнала, снимает его одной строкой вместо того, чтобы
--- собирать цепочку заново.
---
--- Слой, нужный не всякому запросу, стоит в цепочке с фильтром по пути
--- и способу — `{ 'cors', { origins = { … } }, path = '/api' }`,
--- `{ 'throttle', { per_minute = 60 }, method = 'POST' }`, — и запрос мимо
--- фильтра идёт мимо слоя. Так межсайтовые заголовки или счётчик по адресу
--- ставятся один раз на входе роутера, а не на каждую группу маршрутов
--- руками.
---
--- Ошибка объявления — исключение, и место в нём — строка приложения,
--- которая позвала вход пакета (`tnt.middleware.blame`): незнакомое имя
--- в `chain({ 'lgo' })` показывает на эту строку, а не на реестр, где его
--- искали. Входы фасада передают работу реестру хвостовым вызовом:
--- своего кадра у хвостового вызова нет, и вход реестра винит того, кто
--- позвал фасад.

local blame = require('tnt.middleware.blame')
local common = require('tnt.middleware.layer.common')
local registry = require('tnt.middleware.registry')

local Module = {}

--- Готовые слои: доступны и без реестра, тем, кто собирает цепочку руками.
Module.layer = registry.BUILTIN

--- Поле контекста с опознавателем запроса.
---
--- Часть договора с роутером и клиентом: по этому имени они кладут
--- в ответ заголовок, а журнал ищет, чем связать записи.
Module.REQUEST_FIELD = common.REQUEST_FIELD

--- Заголовок, которым опознаватель запроса ходит между узлами.
---
--- Та же часть договора, с другой стороны: этим именем слой
--- `request_id_header` называет опознаватель в ответе, и им же проще
--- всего искать пришедший в запросе.
Module.REQUEST_HEADER = common.REQUEST_HEADER

--- Настройки последнего `configure`; из них собирается общий реестр.
---@type TntMiddlewareOptions
local settings = {}

--- Общий на процесс реестр. Заводится при первом обращении, а не при
--- загрузке модуля: загрузка не должна ничего делать.
---@type TntMiddleware|nil
local shared

--- Настраивает общий конвейер.
---
--- Объявления проверяются здесь же, а не при сборке первой цепочки:
--- фабрика-опечатка обязана обнаружиться при настройке узла, а не
--- на первом запросе, когда отвечать уже надо.
---@param opts TntMiddlewareOptions|nil
function Module.configure(opts)
    settings = blame.call(registry.check, opts)

    -- Прежний реестр забывается: иначе перенастройка не дошла бы до тех,
    -- кто уже взял общий, и узел работал бы по двум настройкам сразу.
    shared = nil
end

--- Заводит отдельный реестр со своими объявлениями.
---
--- Нужен там, где конвейеров два: у административных маршрутов свои слои,
--- у служебного порта свои, и общими им быть незачем.
---@param opts TntMiddlewareOptions|nil
---@return TntMiddleware
function Module.new(opts)
    return registry.new(opts)
end

--- Общий на процесс реестр.
---@return TntMiddleware
function Module.default()
    if shared == nil then
        shared = registry.new(settings)
    end

    return shared
end

--- Собирает цепочку из записей общего реестра.
---@param entries any Список записей, одно имя или nil
---@return TntMiddlewareChain
function Module.chain(entries)
    return Module.default():chain(entries)
end

--- Объявляет слой в общем реестре.
---@param name string
---@param factory fun(options: table): TntMiddlewareFn
---@return TntMiddleware
function Module.register(name, factory)
    return Module.default():register(name, factory)
end

--- Объявляет группу слоёв в общем реестре.
---@param name string
---@param entries any[]
---@return TntMiddleware
function Module.group(name, entries)
    return Module.default():group(name, entries)
end

--- Что объявлено в общем реестре. Ни паролей, ни ключей здесь не бывает:
--- имена слоёв и групп да метка журнала.
---@return { tag: string, layers: string[], groups: string[] }
function Module.status()
    return Module.default():status()
end

return Module
