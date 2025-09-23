import MetaTrader5 as mt5
import pandas as pd

from utils.keys import Keys as k
import os

# Авторизация в MT5
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

# Получаем все символы из терминала
symbols = mt5.symbols_get()

# Собираем названия всех инструментов в список
all_spot = []
for symbol in symbols:
    all_spot.append(symbol.name)

# Переводим в DataFrame для сохранения
all_spot = pd.DataFrame(all_spot)

print(f"Количество инструментов: {len(symbols)}")

# Определяем путь к папке datasets (рядом со скриптом)
datasets_dir = os.path.join(os.path.dirname(__file__), 'datasets')

# Создаем папку datasets, если она не существует
if not os.path.exists(datasets_dir):
    os.makedirs(datasets_dir)

# Сохраняем полный список инструментов
all_spot.to_csv(os.path.join(datasets_dir, f"all_symbols.csv"), index=False)

# Отдельный список инструментов, содержащих 'USD' в названии (часто валютные пары)
currency_pairs = [symbol.name for symbol in symbols if "USD" in symbol.name]
currency_pairs = pd.DataFrame(currency_pairs)
currency_pairs.to_csv(os.path.join(datasets_dir, f"currency_pairs.csv"), index=False)

