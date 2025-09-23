import MetaTrader5 as mt5
from utils.keys import Keys as k
import pandas as pd
import numpy as np
import pandas_ta as ta
from scipy.signal import argrelextrema
import time
import math

# ─────────────── Параметры стратегии ───────────────
# order — «половина окна» для поиска локальных экстремумов (см. argrelextrema)
order = 36  # ширина окна лок-экстремума
RSI_PERIOD = 14  # период RSI
DIV_LOOKBACK = 97  # глубина поиска дивергенций
SIGNAL_EXPIRY = 130  # «срок годности» сигнала, баров
RISK_RATIO = 4  # TP = SL * RISK_RATIO
RISK_PERCENT = 1  # % капитала в риск
SYMBOLS = ["EURUSD"]  # список инструментов

# ─────────────────────── Авторизация ───────────────────────
# Инициализируем подключение к MT5 с использованием данных из utils/keys.py
authorized = mt5.initialize(
    login=int(k.name),
    server=k.serv,
    password=k.key,
    path=k.path
)

if not authorized:
    print("❌ Не удалось авторизоваться:", mt5.last_error())
    mt5.shutdown()
    quit()
else:
    print(f"✅ Успешная авторизация, ваш счёт: {k.name}")

# ─────────────────────── Основной цикл ───────────────────────
# Бесконечный цикл сканирует рынок и, при наличии сигнала, отправляет ордер
while True:
    print("\n*        Прогон начат       *")

    # Баланс и открытые позиции
    account_info = mt5.account_info()
    total_positions = mt5.positions_total()

    if account_info:
        print("*****************************")
        print(f"Баланс:  {account_info.balance}")
        print(f"Эквити:  {account_info.equity}")
        print(f"Позиции: {total_positions}")
        print("*****************************")
    else:
        print("Не удалось получить информацию о счёте")

    # ──── Внутренние функции ────
    def get_data(symbol, timeframe=mt5.TIMEFRAME_M1, bars: int = 4000):
        """Загружает историю свечей из MT5 и возвращает DataFrame с колонкой time (datetime)."""
        rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
        if rates is None:
            print(f"❌ copy_rates_from_pos вернул None для {symbol}")
            return None
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        print(f"[get_data] {symbol}: загружено {len(df)} баров, "
              f"последняя свеча {df['time'].iloc[-1]}")
        return df

    def apply_indicators(df):
        """Добавляет индикаторы в DataFrame (сейчас — только RSI)."""
        df["RSI"] = ta.rsi(df["close"], length=RSI_PERIOD)
        print("[apply_indicators] RSI рассчитан, последние 3 значения:",
              df["RSI"].tail(3).values)
        return df

    def find_nearest_extremum(df, direction: str):
        """Возвращает ближайший (по индексу) локальный экстремум цены до последнего бара.

        direction: 'buy' — ищем последний локальный минимум, 'sell' — локальный максимум.
        """
        closes = df["close"].values
        if direction == "buy":
            mins = argrelextrema(closes, np.less_equal, order=order)[0]
            mins = mins[mins < len(closes) - 1]
            if mins.size:
                return closes[mins.max()]
        else:
            maxs = argrelextrema(closes, np.greater_equal, order=order)[0]
            maxs = maxs[maxs < len(closes) - 1]
            if maxs.size:
                return closes[maxs.max()]
        return None

    def check_strategy(df):
        """Ищет дивергенции RSI/цены в срезе последних DIV_LOOKBACK баров и
        возвращает сигнал 'buy'/'sell' или None, если подходящих не найдено.
        """
        df_recent = df.tail(DIV_LOOKBACK).copy()

        # Индексы локальных экстремумов цены (по закрытию)
        local_min_idx = argrelextrema(df_recent["close"].values,
                                      np.less_equal, order=order)[0]
        local_max_idx = argrelextrema(df_recent["close"].values,
                                      np.greater_equal, order=order)[0]

        bull_div_points, bear_div_points = [], []

        # Бычьи дивергенции: цена ниже, RSI выше
        for prev, curr in zip(local_min_idx[:-1], local_min_idx[1:]):
            if (df_recent["close"].iloc[curr] < df_recent["close"].iloc[prev] and
                    df_recent["RSI"].iloc[curr] > df_recent["RSI"].iloc[prev]):
                bull_div_points.append((prev, curr))

        # Медвежьи дивергенции: цена выше, RSI ниже
        for prev, curr in zip(local_max_idx[:-1], local_max_idx[1:]):
            if (df_recent["close"].iloc[curr] > df_recent["close"].iloc[prev] and
                    df_recent["RSI"].iloc[curr] < df_recent["RSI"].iloc[prev]):
                bear_div_points.append((prev, curr))

        # Выбираем последний актуальный сигнал в пределах «срока годности»
        last_signal = 0
        price = df_recent["close"].iloc[-1]
        current_bar = len(df_recent) - 1

        for _, curr in bull_div_points:
            price_prev = df_recent["close"].iloc[curr]
            if (current_bar - curr) <= SIGNAL_EXPIRY and price > price_prev:
                last_signal = 1
        for _, curr in bear_div_points:
            price_prev = df_recent["close"].iloc[curr]
            if (current_bar - curr) <= SIGNAL_EXPIRY and price < price_prev:
                last_signal = -1

        return "buy" if last_signal == 1 else "sell" if last_signal == -1 else None

    def calc_lot(balance: float,
                 entry: float,
                 stop: float,
                 symbol: str,
                 risk_percent: float = RISK_PERCENT) -> float | None:
        """Вычисляет объём в лотах исходя из допустимого риска и дистанции до SL.

        Правило:
        - Считаем риск в деньгах как balance * risk_percent/100
        - Стоимость пункта берём из trade_contract_size и point
        - Проверяем доступную маржу, постепенно уменьшая объём, пока он допустим
        """
        info = mt5.symbol_info(symbol)
        acc = mt5.account_info()
        if info is None or acc is None:
            return None

        stop_distance = abs(entry - stop)
        if stop_distance < info.point:
            return None

        pip_cost = info.trade_contract_size * info.point
        risk_money = balance * risk_percent / 100
        lots_raw = risk_money / ((stop_distance / info.point) * pip_cost)

        # Округление по шагу лота
        step_decimals = len(str(info.volume_step).split('.')[-1].rstrip('0'))
        lots = math.floor(lots_raw / info.volume_step) * info.volume_step
        lots = max(lots, info.volume_min)
        lots = min(lots, info.volume_max)

        # Проверка на достаточность свободной маржи
        while lots >= info.volume_min:
            margin_needed = mt5.order_calc_margin(
                mt5.TRADE_ACTION_DEAL,
                symbol,
                lots,
                entry,
                mt5.order_TYPE_BUY
            )
            if margin_needed is not None and margin_needed <= acc.margin_free:
                return round(lots, step_decimals)

            lots = round(lots - info.volume_step, step_decimals)

        return None

    def get_position_type(symbol):
        """Возвращает тип открытой позиции по символу или None, если позиций нет."""
        positions = mt5.positions_get(symbol=symbol)
        if positions is None:
            print(f"⚠️ positions_get вернул None для {symbol}: {mt5.last_error()}")
            return None
        if positions:
            pos = positions[0]
            return "buy" if pos.type == mt5.order_TYPE_BUY else "sell"
        return None

    def close_position(symbol, opposite):
        """Закрывает открытую позицию, если она противоположна новому сигналу opposite."""
        positions = mt5.positions_get(symbol=symbol)
        if not positions:
            return
        for pos in positions:
            need = (pos.type == mt5.order_TYPE_BUY and opposite == "sell") or \
                   (pos.type == mt5.order_TYPE_SELL and opposite == "buy")
            if not need:
                continue

            price = (mt5.symbol_info_tick(symbol).bid
                     if pos.type == mt5.order_TYPE_BUY
                     else mt5.symbol_info_tick(symbol).ask)

            close_req = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": symbol,
                "volume": pos.volume,
                "type": (mt5.order_TYPE_SELL
                         if pos.type == mt5.order_TYPE_BUY
                         else mt5.order_TYPE_BUY),
                "position": pos.ticket,
                "price": price,
                "deviation": 20,
                "magic": 123456,
                "comment": "Close opposite",
                "type_time": mt5.order_TIME_GTC,
                "type_filling": mt5.order_FILLING_FOK,
            }
            res = mt5.order_send(close_req)
            if res.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"🗙 Закрыта позиция {pos.ticket}")

    def open_order(symbol, lot, order_type, sl, tp):
        """Открывает рыночный ордер указанного типа с заданными SL/TP.

        Примечание: если по символу уже есть позиция, сигнал игнорируется.
        """
        info = mt5.symbol_info(symbol)
        if info is None:
            print(f"⚠️ open_order: нет symbol_info для {symbol}")
            return

        # ❶ : игнорируем сигнал, если позиция уже есть
        if get_position_type(symbol) is not None:
            print(f"↷ {symbol}: позиция уже открыта, сигнал {order_type} игнорируем")
            return

        if lot is None or lot < info.volume_min:
            print(f"↷ Пропуск: объём {lot} меньше минимального {info.volume_min}")
            return

        tick = mt5.symbol_info_tick(symbol)
        price = tick.ask if order_type == "buy" else tick.bid

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": lot,
            "type": (mt5.order_TYPE_BUY
                     if order_type == "buy"
                     else mt5.order_TYPE_SELL),
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": 123456,
            "comment": f"Divergence {order_type.upper()}",
            "type_time": mt5.order_TIME_GTC,
            "type_filling": mt5.order_FILLING_IOC,
        }

        result = mt5.order_send(request)
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"✅ Открыт {order_type.upper()} по {symbol} на {lot} лотов")
        else:
            print(f"❌ Ошибка открытия {symbol}: retcode {result.retcode}")

    # ─────── Торговый прогон по символам ───────
    for symbol in SYMBOLS:
        # 1) Данные и индикаторы
        df = get_data(symbol)
        if df is None or len(df) < DIV_LOOKBACK + order * 2 + 1:
            # Недостаточно данных для корректной работы экстремумов/дивергенций
            continue

        df = apply_indicators(df)

        # 2) Простейшие экстремумы на роллинге по high/low для SL
        period = order
        df["min_low_roll"]  = df["low"].rolling(window=period,  min_periods=1).min()
        df["max_high_roll"] = df["high"].rolling(window=period, min_periods=1).max()

        # 3) Сигнал по дивергенциям
        signal = check_strategy(df)
        if not signal:
            continue

        entry_price = df["close"].iloc[-1]

        # 4) Стоп-лосс как ближайший экстремум
        if signal == "buy":
            sl_price = df["min_low_roll"].iloc[-1]
        else:
            sl_price = df["max_high_roll"].iloc[-1]

        if sl_price is None:
            print(f"↷ {symbol}: не найден экстремум для SL")
            continue

        # 5) Тейк-профит кратно расстоянию до стопа
        tp_price = (entry_price + abs(entry_price - sl_price) * RISK_RATIO
                    if signal == "buy"
                    else entry_price - abs(entry_price - sl_price) * RISK_RATIO)

        # 6) Расчёт объёма исходя из риска и проверка доступной маржи
        lot_size = calc_lot(account_info.balance, entry_price, sl_price, symbol)
        if lot_size is None:
            continue

        # 7) Отправка ордера
        open_order(symbol, lot=lot_size, order_type=signal,
                   sl=sl_price, tp=tp_price)

    print("*****************************")
    print("*      Прогон завершён      *\n")
    # Пауза между прогонами, чтобы не перегружать терминал и не спамить запросами
    time.sleep(5)
