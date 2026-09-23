rockspec_format = '3.0'

package = 'tnt-middleware'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-middleware.git',
    branch = 'main',
}

description = {
    summary = 'Конвейер слоёв обработки: один механизм для входящего запроса и исходящего',
    detailed = [[
        Слой — функция (context, next): всё до next случается на входе,
        всё после — на выходе, а не позвав next, слой отвечает сам.
        Один и тот же конвейер годится и роутеру, и клиенту: о виде
        запроса и ответа он ничего не знает.

        Цепочка собирается из объявленных слоёв и групп, слои именуются
        и переставляются (before, after, without), слой ставится
        с фильтром по началу пути и способу запроса. Цепочка не бросает
        и не возвращает пустоты: брошенная ошибка становится отказом
        парой nil, err, называет виновный слой и несёт стек места броска,
        а слой, забывший позвать next или вернуть его ответ, не остаётся
        незамеченным.

        Готовые слои общего назначения: журнал, время ответа, перехват
        отказа, опознаватель запроса и его же заголовком в ответе.
        Опознаватель — ULID; слой кладёт его в контекст файбера, откуда
        журнал берёт его в каждую запись остатка цепочки.

        Слой cors разрешает чужим страницам читать ответы по списку
        источников — точных и образцом поддомена, — сам отвечает
        на предварительный OPTIONS и по умолчанию не разрешает ничего,
        что не названо: способы, заголовки, срок и учётные данные.
        Звёздочка вместе с учётными данными отвергается при сборке.

        Зависит от tnt-clock (монотонные часы замера), tnt-context
        (контекст файбера с опознавателем запроса), tnt-id (ULID),
        tnt-log (журнал готовых слоёв), tnt-must (проверка настроек
        слоя cors и бросок отказа объявления без места) и tnt-external
        (подмена часов и выдачи опознавателей в проверках). Ошибка
        объявления называет строку приложения, позвавшую вход пакета.
        Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-middleware',
    issues_url = 'https://github.com/tnt-skein/tnt-middleware/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'middleware', 'pipeline', 'http', 'request-id', 'cors' },
}

dependencies = {
    'lua >= 5.1',
    'tnt-clock',
    'tnt-context',
    'tnt-id',
    'tnt-log',
    'tnt-must',
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.middleware'] = 'tnt/middleware.lua',
        ['tnt.middleware.blame'] = 'tnt/middleware/blame.lua',
        ['tnt.middleware.chain'] = 'tnt/middleware/chain.lua',
        ['tnt.middleware.fall'] = 'tnt/middleware/fall.lua',
        ['tnt.middleware.filter'] = 'tnt/middleware/filter.lua',
        ['tnt.middleware.registry'] = 'tnt/middleware/registry.lua',
        ['tnt.middleware.layer.common'] = 'tnt/middleware/layer/common.lua',
        ['tnt.middleware.layer.cors'] = 'tnt/middleware/layer/cors.lua',
        ['tnt.middleware.layer.log'] = 'tnt/middleware/layer/log.lua',
        ['tnt.middleware.layer.timing'] = 'tnt/middleware/layer/timing.lua',
        ['tnt.middleware.layer.rescue'] = 'tnt/middleware/layer/rescue.lua',
        ['tnt.middleware.layer.request_id'] = 'tnt/middleware/layer/request_id.lua',
        ['tnt.middleware.layer.request_id_header'] = 'tnt/middleware/layer/request_id_header.lua',
    },
}
