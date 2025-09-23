import MetaTrader5 as mt5
import pandas as pd

from utils.keys import Keys as k
import os

# Авторизация в MT5 по данным из utils/keys.py
authorized = mt5.initialize(login = int(k.name), server = k.serv, password = k.key, path = k.path)

if not authorized:
    print("Не удалось авторизоваться")
    print(mt5.last_error())
    mt5.shutdown()
    quit()
else:
    print(f"Успешная авторизация, ваш счет: {k.name}")

# Получаем информацию о балансе счета
account_info = mt5.account_info()
if account_info is not None:
    print(f"Баланс: {account_info.balance}")
else:
    print("Не удалось получить информацию о счете")


# Функция для получения данных с любого символа и таймфрейма
def get_symbol_data(symbol, timeframe, bars=100):
    """
    Возвращает DataFrame со свечными данными по указанному символу и таймфрейму.

    Параметры:
        symbol (str): тикер, например 'EURUSD'
        timeframe (str): ключ из словаря timeframes ниже, например 'M5'
        bars (int): количество запрашиваемых баров (с последних позиций)
    """
    # Получаем исторические данные
    rates = mt5.copy_rates_from_pos(symbol, timeframes[timeframe], 0, bars)

    if rates is None:
        print(f"Не удалось получить данные для символа {symbol}")
        return None

    # Преобразуем в DataFrame и дату в формат datetime
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    return df


# Доступные таймфреймы (маппинг строкового ключа к константам MT5)
timeframes = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1": mt5.TIMEFRAME_H1,
    "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
    "W1": mt5.TIMEFRAME_W1,
    "MN1": mt5.TIMEFRAME_MN1
}

# Параметры примера запроса
symbol = "EURUSD"
timeframe = "M5"
bars = 34000

# Получаем данные по символу и таймфрейму
data = get_symbol_data(symbol, timeframe, bars)

# Проверяем результат и сохраняем в CSV
if data is not None:
    print(f"Данные для символа {symbol} на таймфрейме {timeframe}:")
    print(data.head())  # Выводим первые строки DataFrame для проверки

    # Определяем путь к папке datasets (рядом с данным скриптом)
    datasets_dir = os.path.join(os.path.dirname(__file__), 'datasets')

    # Создаем папку datasets, если она не существует
    if not os.path.exists(datasets_dir):
        os.makedirs(datasets_dir)

    # Сохраняем DataFrame в файл с названием вида EURUSD_M5.csv
    data.to_csv(os.path.join(datasets_dir, f"{symbol.replace('/', '')}_{timeframe}.csv"), index=False)
else:
    print("Данные не получены")

