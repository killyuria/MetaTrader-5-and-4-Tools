import pandas as pd
import backtrader as bt
import os
import quantstats
import warnings

warnings.filterwarnings('ignore')

# -------------------------------------------------------
# Загрузка данных
# -------------------------------------------------------
current_dir = os.path.dirname(os.path.abspath(__file__))
# Папка с датасетами расположена в utils/datasets относительно текущего файла
datasets_dir = os.path.abspath(os.path.join(current_dir, '..', 'utils', 'datasets'))

# Имя файла датасета (EURUSD таймфрейм M5)
symbol = 'EURUSD_M5'
csv_path = os.path.join(datasets_dir, f"{symbol}.csv")

# Читаем CSV с историей, приводим столбцы к нижнему регистру и парсим время
data = pd.read_csv(csv_path)
data['time'] = pd.to_datetime(data['time'])
data.columns = data.columns.str.lower()


class TestStrategy(bt.Strategy):
    """Стратегия поиска дивергенций по RSI с управлением риском.

    Идея:
    - Находим локальные экстремумы цены за окно (2*for_extremum+1)
    - Ищем бычьи/медвежьи дивергенции между ценой и RSI
    - Формируем сигнал, валидный ограниченное число баров (signal_expiry)
    - Считаем стоп-лосс по ближайшему локальному экстремуму, тейк-профит как SL*risk_ratio
    - Размер позиции в контрактах рассчитываем как фиксированную долю капитала (risk_percent)
    """

    params = (
        ('for_extremum', 36),  # половина окна для поиска локальных экстремумов
        ('risk_ratio', 4),     # отношение TP к SL
        ('rsiperiod', 4),      # период RSI
        ('div_lookback', 97),  # глубина поиска дивергенций по истории
        ('signal_expiry', 130), # «срок годности» сигнала (в барах)

        ('risk_percent', 1),   # доля капитала на сделку, %
        ('point_value', 900),  # стоимость 1 пункта, руб. (для Backtrader-симуляции)
    )

    def log(self, txt, dt=None):
        """Вывод логов (по умолчанию выключен, оставлен для отладки)."""
        dt = dt or self.datas[0].datetime.date(0)
        # print(f"{dt.isoformat()}, {txt}")

    def __init__(self):
        # Ссылки на основные серии данных
        self.close = self.datas[0].close
        self.rsi = bt.indicators.RSI(self.datas[0], period=self.params.rsiperiod)

        # Для поиска локальных минимумов/максимумов используем окно 2*for_extremum+1
        win_len = self.params.for_extremum * 2 + 1
        self.minlow = bt.indicators.Lowest(self.data.low, period=win_len)
        self.maxhigh = bt.indicators.Highest(self.data.high, period=win_len)

        # Истории цен и RSI (списки синхронизированы по индексу бара)
        self.close_history = []
        self.rsi_history = []

        # Индексы обнаруженных локальных минимумов и максимумов
        self.local_min_idx = set()
        self.local_max_idx = set()

        # Индексы дивергенций, которые уже были использованы для открытия сделки
        self.used_divergence_idx = set()

        # Текущие торговые параметры состояния
        self.buy_signal = False
        self.sell_signal = False
        self.order_ref = None
        self.entry_price = None
        self.stop_loss = None
        self.take_profit = None

    def find_divergences(self, current_idx):
        """Ищет бычьи и медвежьи дивергенции в пределах div_lookback.

        Возвращает:
            bull_points: список (prev_idx, curr_idx, price_prev)
            bear_points: список (prev_idx, curr_idx, price_prev)
        """
        bull_points, bear_points = [], []
        start_idx = max(0, current_idx - self.params.div_lookback)

        # Бычья дивергенция: цена делает более низкий минимум, RSI — более высокий минимум
        valid_mins = [i for i in sorted(self.local_min_idx)
                      if start_idx <= i < current_idx and i not in self.used_divergence_idx]
        for prev, curr in zip(valid_mins, valid_mins[1:]):
            c_prev, c_curr = self.close_history[prev], self.close_history[curr]
            r_prev, r_curr = self.rsi_history[prev], self.rsi_history[curr]
            if c_curr < c_prev and r_curr > r_prev:
                bull_points.append((prev, curr, c_prev))

        # Медвежья дивергенция: цена делает более высокий максимум, RSI — более низкий максимум
        valid_maxs = [i for i in sorted(self.local_max_idx)
                      if start_idx <= i < current_idx and i not in self.used_divergence_idx]
        for prev, curr in zip(valid_maxs, valid_maxs[1:]):
            c_prev, c_curr = self.close_history[prev], self.close_history[curr]
            r_prev, r_curr = self.rsi_history[prev], self.rsi_history[curr]
            if c_curr > c_prev and r_curr < r_prev:
                bear_points.append((prev, curr, c_prev))

        return bull_points, bear_points

    def find_nearest_extremum(self, direction, current_idx):
        """Возвращает цену ближайшего локального экстремума до current_idx.

        direction: 'buy' => ближайший локальный минимум, 'sell' => ближайший локальный максимум
        """
        if direction == 'buy':
            mins = [i for i in self.local_min_idx if i < current_idx]
            if mins:
                return self.close_history[max(mins)]
        else:
            maxs = [i for i in self.local_max_idx if i < current_idx]
            if maxs:
                return self.close_history[max(maxs)]
        return None

    def notify_order(self, order):
        """Обработка статусов ордера (логирование/сброс ссылки на активный ордер)."""
        if order.status in [order.Submitted, order.Accepted]:
            return
        if order.status in [order.Completed]:
            if order.isbuy():
                self.log(f"Покупка выполнена, Цена: {order.executed.price:.5f}, "
                         f"На сумму: {order.executed.value:.2f}, Комиссия {order.executed.comm:.2f}")
                self.buyprice, self.buycomm = order.executed.price, order.executed.comm
            else:
                self.log(f"Продажа выполнена, Цена: {order.executed.price:.5f}, "
                         f"На сумму: {order.executed.value:.2f}, Комиссия {order.executed.comm:.2f}")
            self.bar_executed = len(self)
        elif order.status in [order.Canceled, order.Margin, order.Rejected]:
            self.log('Отмена ордера')
        self.order_ref = None

    def notify_trade(self, trade):
        """Логируем результат сделки после её закрытия."""
        if not trade.isclosed:
            return
        self.log(f"Операционная прибыль, Общая {trade.pnl:.2f}, С учетом комиссии {trade.pnlcomm:.2f}")

    def next(self):
        """Основной шаг стратегии на каждом баре.

        1) Обновляем истории цен/RSI и множества локальных экстремумов
        2) Ищем дивергенции и формируем сигнал, если он ещё валиден
        3) Управляем позициями: выходим по SL/TP или открываем новую сделку
        """
        # Ждём, пока накопится достаточно баров для расчёта RSI
        if len(self) < self.params.rsiperiod:
            return

        # Текущие значения индикаторов/цены
        price = float(self.close[0])
        high_price = float(self.data.high[0])
        r_val = float(self.rsi[0])

        # Накапливаем историю для последующего анализа дивергенций
        self.close_history.append(price)
        self.rsi_history.append(r_val)
        current_idx = len(self.close_history) - 1

        # Отмечаем локальные экстремумы через индикаторы Lowest/Highest
        min_low_val, max_high_val = float(self.minlow[0]), float(self.maxhigh[0])
        if price == min_low_val:
            self.local_min_idx.add(current_idx)
        if high_price == max_high_val:
            self.local_max_idx.add(current_idx)

        # Ищем дивергенции только если накопили достаточную историю
        bulls, bears = (self.find_divergences(current_idx)
                        if len(self.close_history) >= self.params.div_lookback else ([], []))

        # Сбрасываем прошлые сигналы и проверяем новые (первый подходящий берём)
        self.buy_signal = self.sell_signal = False
        for prev, curr, p_prev in bulls:
            # Сигнал валиден не дольше signal_expiry баров, подтверждение — цена выше опорной точки
            if (current_idx - curr) <= self.params.signal_expiry and price > p_prev:
                self.buy_signal, sel_idx = True, curr
                break
        for prev, curr, p_prev in bears:
            if (current_idx - curr) <= self.params.signal_expiry and price < p_prev:
                self.sell_signal, sel_idx = True, curr
                break

        # Сопровождение открытой позиции: закрываем по SL/TP
        if self.position and self.entry_price is not None:
            if self.position.size > 0 and (price <= self.stop_loss or price >= self.take_profit):
                self.order_ref = self.sell()
            elif self.position.size < 0 and (price >= self.stop_loss or price <= self.take_profit):
                self.order_ref = self.buy()
            if self.order_ref:
                return

        # Открытие новой позиции по сигналу BUY
        if self.buy_signal:
            sl = self.find_nearest_extremum('buy', current_idx)
            # Дистанция до стопа должна быть положительной
            if sl and (stop_dist := price - sl) > 0:
                # Простейшее риск-менеджмент через стоимость пункта
                contracts = int((self.broker.getvalue() * self.params.risk_percent / 100)
                                / (stop_dist * self.params.point_value))
                if contracts > 0:
                    self.entry_price, self.stop_loss = price, sl
                    self.take_profit = price + stop_dist * self.params.risk_ratio
                    self.order_ref = self.buy(size=contracts)
                    # Помечаем использованную дивергенцию, чтобы не повторять вход
                    self.used_divergence_idx.add(sel_idx)

        # Открытие новой позиции по сигналу SELL
        elif self.sell_signal:
            sl = self.find_nearest_extremum('sell', current_idx)
            if sl and (stop_dist := sl - price) > 0:
                contracts = int((self.broker.getvalue() * self.params.risk_percent / 100)
                                / (stop_dist * self.params.point_value))
                if contracts > 0:
                    self.entry_price, self.stop_loss = price, sl
                    self.take_profit = price - stop_dist * self.params.risk_ratio
                    self.order_ref = self.sell(size=contracts)
                    self.used_divergence_idx.add(sel_idx)


if __name__ == '__main__':
    # Настраиваем «движок» Backtrader
    cerebro = bt.Cerebro()
    cerebro.addstrategy(
        TestStrategy,
        for_extremum=5,   # примеры значений параметров для прогона
        rsiperiod=14,
        div_lookback=3650,
        signal_expiry=20,
        risk_ratio=3
    )

    # Анализатор PyFolio (возвращает pandas Series доходностей и пр.)
    cerebro.addanalyzer(bt.analyzers.PyFolio, _name='PyFolio')

    # Источник данных: PandasData по индексу времени
    data.set_index('time', inplace=True)
    cerebro.adddata(bt.feeds.PandasData(dataname=data))

    # Начальные настройки брокера/комиссии
    cerebro.broker.setcash(100000.0)
    cerebro.broker.setcommission(commission=0.001)

    print(f"Стартовый портфель: {cerebro.broker.getvalue():.2f}")
    results = cerebro.run()
    print(f"Конечный портфель: {cerebro.broker.getvalue():.2f}")

    # Формирование отчёта QuantStats
    strat = results[0]
    pf_stats = strat.analyzers.getbyname('PyFolio')
    returns, positions, transactions, gross_lev = pf_stats.get_pf_items()
    # Убираем таймзону для совместимости с quantstats
    returns.index = returns.index.tz_convert(None)
    quantstats.reports.html(
        returns,
        output=f"{__file__}_{symbol}.html",
        title='Анализ по стратегии'
    )
