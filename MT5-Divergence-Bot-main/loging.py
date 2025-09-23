import MetaTrader5 as mt5
from utils.keys import Keys as k
import time

# Авторизация в терминале MT5
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


def get_position_type(symbol):
    """
    Возвращает тип открытой позиции для символа.

    'buy' — если открыта позиция на покупку,
    'sell' — если открыта позиция на продажу,
    None — если нет открытых позиций или произошла ошибка.
    """
    positions = mt5.positions_get(symbol=symbol)
    if positions is None:
        print(f"Ошибка получения позиций для символа {symbol}: {mt5.last_error()}")
        return None
    elif len(positions) > 0:
        position = positions[0]
        if position.type == mt5.ORDER_TYPE_BUY:
            return 'buy'
        elif position.type == mt5.ORDER_TYPE_SELL:
            return 'sell'
    return None


def open_order(symbol, lot, order_type):
    """Открывает рыночный ордер указанного типа с заданным объёмом.

    Предварительно проверяет, не открыта ли уже позиция того же типа по символу.
    """
    position_type = get_position_type(symbol)

    # Если позиция того же направления уже открыта — пропускаем
    if position_type == 'buy' and order_type == 'buy':
        print(f"Позиция на покупку по {symbol} уже открыта. Новый ордер на покупку не будет отправлен.")
        return
    elif position_type == 'sell' and order_type == 'sell':
        print(f"Позиция на продажу по {symbol} уже открыта. Новый ордер на продажу не будет отправлен.")
        return

    # Определяем рыночную цену по тикеру (ask для buy, bid для sell)
    price = mt5.symbol_info_tick(symbol).ask if order_type == 'buy' else mt5.symbol_info_tick(symbol).bid
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": lot,
        "type": mt5.ORDER_TYPE_BUY if order_type == 'buy' else mt5.ORDER_TYPE_SELL,
        "price": price,
        "deviation": 20,
        "magic": 123456,
        "comment": f"Order for {symbol}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_FOK
    }

    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"Ошибка открытия ордера для {symbol}: {result.retcode}")
    else:
        print(f"Открыт ордер для {symbol} на {lot} лотов.")


def close_position(symbol, order_type):
    """Закрывает открытую позицию по символу, если она противоположна новому сигналу.

    order_type: 'buy' означает, что поступил сигнал на покупку (закрываем SELL),
                'sell' — поступил сигнал на продажу (закрываем BUY).
    """
    positions = mt5.positions_get(symbol=symbol)

    if positions is None or len(positions) == 0:
        print(f"Нет открытых позиций для {symbol}")
        return

    # Закрываем противоположную позицию
    for position in positions:
        if (position.type == mt5.ORDER_TYPE_BUY and order_type == 'sell') or (
                position.type == mt5.ORDER_TYPE_SELL and order_type == 'buy'):
            print(f"Закрываем позицию {position.ticket} для {symbol} перед открытием {order_type}")

            # Определяем цену и тип ордера для закрытия
            volume = position.volume
            if position.type == mt5.ORDER_TYPE_BUY:
                price = mt5.symbol_info_tick(symbol).bid
                close_type = mt5.ORDER_TYPE_SELL
            else:
                price = mt5.symbol_info_tick(symbol).ask
                close_type = mt5.ORDER_TYPE_BUY

            close_request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": symbol,
                "volume": volume,
                "type": close_type,
                "position": position.ticket,  # Указываем тикет позиции для закрытия
                "price": price,
                "deviation": 20,
                "magic": 123456,
                "comment": f"Closing {position.type} position for {symbol}",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": mt5.ORDER_FILLING_FOK
            }

            # Отправляем запрос на закрытие позиции
            result = mt5.order_send(close_request)
            if result.retcode != mt5.TRADE_RETCODE_DONE:
                print(f"Ошибка закрытия позиции для {symbol}: {result.retcode}")
            else:
                print(f"Закрыта позиция для {symbol} на {volume} лотов.")


# Пример сценария работы: открытие BUY, пауза, закрытие и открытие SELL
symbol = "EURUSD"

open_order(symbol, lot=0.1, order_type='buy')

time.sleep(10)

close_position(symbol, order_type='sell')

open_order(symbol, lot=0.1, order_type='sell')