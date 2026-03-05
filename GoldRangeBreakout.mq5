//+------------------------------------------------------------------+
//|                                          GoldRangeBreakout.mq5   |
//|                         Gold Range Breakout Strategy v3.0         |
//|                         Timeframe: 5 min - XAUUSD                |
//+------------------------------------------------------------------+
#property copyright   "Gold Range Breakout Bot"
#property link        ""
#property version     "3.00"
#property strict
#property description "Range breakout strategy for Gold (XAUUSD) v3.0"
#property description "Trend filter, entry buffer, partial close, trailing stop."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Range Time Settings (New York Time) ==="
input int    InpRangeStartHour   = 7;    // Range Start Hour (NY Time)
input int    InpRangeStartMinute = 30;   // Range Start Minute
input int    InpRangeEndHour     = 7;    // Range End Hour (NY Time)
input int    InpRangeEndMinute   = 45;   // Range End Minute
input int    InpBrokerGMTOffset  = 2;    // Broker GMT Offset (hours, e.g. 2 for UTC+2)
input int    InpDeletePendingHour   = 10; // Hour (NY) to delete unfilled orders
input int    InpDeletePendingMinute = 0;  // Minute to delete unfilled orders

input group "=== Trade Settings ==="
input double InpLotSize          = 0.01; // Lot Size
input double InpTPMultiplier     = 3.0;  // Take Profit (R multiples)
input double InpEntryBuffer      = 0.50; // Entry Buffer above/below range (price units, e.g. 0.50 for gold)
input bool   InpUseBreakEven     = true; // Enable Break-Even at 1:1
input int    InpMaxSpreadPoints  = 50;   // Max Spread (points, 0=disabled)

input group "=== Trend Filter (Higher Timeframe) ==="
input bool   InpUseTrendFilter   = true;  // Enable Trend Filter
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1; // Trend Timeframe
input int    InpEMAPeriod        = 200;   // EMA Period for Trend
input ENUM_TIMEFRAMES InpFastTrendTF = PERIOD_M15; // Fast Trend Timeframe
input int    InpFastEMAPeriod    = 50;    // Fast EMA Period

input group "=== Range Size Filters ==="
input double InpMinRangePoints   = 30;    // Minimum Range Size (points)
input double InpMaxRangePoints   = 500;   // Maximum Range Size (points)

input group "=== Partial Close & Trailing ==="
input bool   InpUsePartialClose  = true;  // Enable Partial Close at 1R
input double InpPartialPercent   = 50.0;  // Partial Close Percentage (%)
input bool   InpUseTrailingStop  = true;  // Enable Trailing Stop (after 1R)
input double InpTrailingRMultiple = 1.0;  // Trail distance in R multiples

input group "=== Day of Week Filter ==="
input bool   InpTradeMonday      = true;  // Trade Monday
input bool   InpTradeTuesday     = true;  // Trade Tuesday
input bool   InpTradeWednesday   = true;  // Trade Wednesday
input bool   InpTradeThursday    = true;  // Trade Thursday
input bool   InpTradeFriday      = true;  // Trade Friday

input group "=== Visual Settings ==="
input color  InpRangeColor       = clrDodgerBlue; // Range Box Color
input int    InpRangeLineWidth   = 2;             // Range Box Border Width
input bool   InpFillRange        = true;          // Fill Range Box
input bool   InpShowRange        = true;          // Show Range Box on Chart

input group "=== General ==="
input ulong  InpMagicNumber      = 777777; // Magic Number
input int    InpSlippage         = 30;     // Slippage (points)

//+------------------------------------------------------------------+
//| State Machine                                                     |
//+------------------------------------------------------------------+
enum ENUM_RANGE_STATE
  {
   STATE_WAITING_FOR_RANGE,
   STATE_BUILDING_RANGE,
   STATE_RANGE_COMPLETE,
   STATE_ORDERS_PLACED,
   STATE_TRADE_ACTIVE,
   STATE_DONE_FOR_DAY
  };

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade            trade;
ENUM_RANGE_STATE  g_state;
double            g_rangeHigh;
double            g_rangeLow;
double            g_rangeSize;
datetime          g_rangeStartTime;
datetime          g_rangeEndTime;
ulong             g_buyTicket;
ulong             g_sellTicket;
bool              g_breakEvenApplied;
bool              g_partialClosed;
int               g_lastDay;
string            g_objPrefix;
int               g_trendEMAHandle;
int               g_fastEMAHandle;
int               g_trendDirection; // 1=bullish, -1=bearish, 0=neutral

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_objPrefix = "GRB_" + IntegerToString(InpMagicNumber) + "_";

// Create EMA indicators for trend filter
   if(InpUseTrendFilter)
     {
      g_trendEMAHandle = iMA(_Symbol, InpTrendTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_fastEMAHandle  = iMA(_Symbol, InpFastTrendTF, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_trendEMAHandle == INVALID_HANDLE || g_fastEMAHandle == INVALID_HANDLE)
        {
         Print("Failed to create EMA indicators!");
         return(INIT_FAILED);
        }
     }

   ResetDailyState();
   g_lastDay = -1;

   Print("GoldRangeBreakout v3.0 initialized. Magic=", InpMagicNumber,
         " BrokerGMT=", InpBrokerGMTOffset,
         " TrendFilter=", InpUseTrendFilter,
         " PartialClose=", InpUsePartialClose);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_trendEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendEMAHandle);
   if(g_fastEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEMAHandle);

   if(reason == REASON_REMOVE || reason == REASON_RECOMPILE)
     {
      ObjectsDeleteAll(0, g_objPrefix);
      ChartRedraw(0);
     }
  }

//+------------------------------------------------------------------+
//| Reset daily state                                                 |
//+------------------------------------------------------------------+
void ResetDailyState()
  {
   g_state            = STATE_WAITING_FOR_RANGE;
   g_rangeHigh        = 0;
   g_rangeLow         = DBL_MAX;
   g_rangeSize        = 0;
   g_rangeStartTime   = 0;
   g_rangeEndTime     = 0;
   g_buyTicket        = 0;
   g_sellTicket       = 0;
   g_breakEvenApplied = false;
   g_partialClosed    = false;
   g_trendDirection   = 0;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();
   MqlDateTime dtNow;
   TimeCurrent(dtNow);

//--- New day: clean up and reset
   if(dtNow.day != g_lastDay)
     {
      CleanupPendingOrders();
      g_lastDay = dtNow.day;
      ResetDailyState();

      // Check day of week filter
      if(!IsTradingDay(dtNow.day_of_week))
        {
         g_state = STATE_DONE_FOR_DAY;
         return;
        }
     }

//--- Calculate broker times
   datetime rangeStart = NYTimeToBroker(InpRangeStartHour, InpRangeStartMinute);
   datetime rangeEnd   = NYTimeToBroker(InpRangeEndHour, InpRangeEndMinute);
   datetime deleteTime = NYTimeToBroker(InpDeletePendingHour, InpDeletePendingMinute);

//--- State machine
   switch(g_state)
     {
      case STATE_WAITING_FOR_RANGE:
         if(now >= rangeStart && now < rangeEnd)
           {
            g_rangeStartTime = rangeStart;
            g_rangeEndTime   = rangeEnd;
            g_rangeHigh      = 0;
            g_rangeLow       = DBL_MAX;
            g_state          = STATE_BUILDING_RANGE;
           }
         break;

      case STATE_BUILDING_RANGE:
         UpdateRangeFromTick();
         if(now >= rangeEnd)
           {
            FinalizeRange();
            if(ValidateRange())
              {
               // Get trend direction BEFORE placing orders
               if(InpUseTrendFilter)
                  g_trendDirection = GetTrendDirection();

               g_state = STATE_RANGE_COMPLETE;
               Print("Range OK: H=", DoubleToString(g_rangeHigh, _Digits),
                     " L=", DoubleToString(g_rangeLow, _Digits),
                     " Size=", DoubleToString(g_rangeSize / _Point, 0), "pts",
                     " Trend=", g_trendDirection);

               if(InpShowRange)
                  DrawRangeBox();
              }
            else
              {
               g_state = STATE_DONE_FOR_DAY;
              }
           }
         break;

      case STATE_RANGE_COMPLETE:
         PlacePendingOrders();
         break;

      case STATE_ORDERS_PLACED:
         CheckOCO();
         if(g_state == STATE_ORDERS_PLACED && now >= deleteTime)
           {
            Print("Cutoff time. Deleting unfilled orders.");
            DeleteAllPendingOrders();
            g_state = STATE_DONE_FOR_DAY;
           }
         break;

      case STATE_TRADE_ACTIVE:
         ManageOpenTrade();
         if(!HasOpenPosition())
           {
            g_state = STATE_DONE_FOR_DAY;
           }
         break;

      case STATE_DONE_FOR_DAY:
         break;
     }
  }

//+------------------------------------------------------------------+
//| Check if today is a trading day                                   |
//+------------------------------------------------------------------+
bool IsTradingDay(int dayOfWeek)
  {
   switch(dayOfWeek)
     {
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      default: return false; // No trading on weekends
     }
  }

//+------------------------------------------------------------------+
//| Get trend direction from EMA                                      |
//| Returns: 1=bullish, -1=bearish, 0=neutral                        |
//+------------------------------------------------------------------+
int GetTrendDirection()
  {
   if(!InpUseTrendFilter)
      return 0;

   double emaValue[1];
   double fastEmaValue[1];

   if(CopyBuffer(g_trendEMAHandle, 0, 0, 1, emaValue) < 1)
      return 0;
   if(CopyBuffer(g_fastEMAHandle, 0, 0, 1, fastEmaValue) < 1)
      return 0;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

// Strong trend: price above both EMAs = bullish, below both = bearish
   if(currentPrice > emaValue[0] && currentPrice > fastEmaValue[0])
      return 1;   // Bullish
   if(currentPrice < emaValue[0] && currentPrice < fastEmaValue[0])
      return -1;  // Bearish

   return 0; // Mixed / neutral - no trade
  }

//+------------------------------------------------------------------+
//| Update range from tick                                            |
//+------------------------------------------------------------------+
void UpdateRangeFromTick()
  {
   double barHigh = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double barLow  = iLow(_Symbol, PERIOD_CURRENT, 0);

   if(barHigh > g_rangeHigh)
      g_rangeHigh = barHigh;
   if(barLow < g_rangeLow)
      g_rangeLow = barLow;
  }

//+------------------------------------------------------------------+
//| Final scan of bars within range window                            |
//+------------------------------------------------------------------+
void FinalizeRange()
  {
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   for(int i = 0; i < bars; i++)
     {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);
      if(barTime < g_rangeStartTime)
         break;
      if(barTime >= g_rangeStartTime && barTime < g_rangeEndTime)
        {
         double h = iHigh(_Symbol, PERIOD_CURRENT, i);
         double l = iLow(_Symbol, PERIOD_CURRENT, i);
         if(h > g_rangeHigh)
            g_rangeHigh = h;
         if(l < g_rangeLow)
            g_rangeLow = l;
        }
     }

   g_rangeHigh = NormalizeDouble(g_rangeHigh, _Digits);
   g_rangeLow  = NormalizeDouble(g_rangeLow, _Digits);
   g_rangeSize = g_rangeHigh - g_rangeLow;
  }

//+------------------------------------------------------------------+
//| Validate range size                                               |
//+------------------------------------------------------------------+
bool ValidateRange()
  {
   if(g_rangeHigh <= 0 || g_rangeLow >= DBL_MAX || g_rangeHigh <= g_rangeLow)
     {
      Print("Range invalid.");
      return false;
     }

   double rangePts = g_rangeSize / _Point;

   if(rangePts < InpMinRangePoints)
     {
      Print("Range too small: ", DoubleToString(rangePts, 0),
            "pts < ", DoubleToString(InpMinRangePoints, 0), "pts min");
      return false;
     }

   if(rangePts > InpMaxRangePoints)
     {
      Print("Range too large: ", DoubleToString(rangePts, 0),
            "pts > ", DoubleToString(InpMaxRangePoints, 0), "pts max");
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Place pending orders with trend filter and buffer                 |
//+------------------------------------------------------------------+
void PlacePendingOrders()
  {
// Check spread
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return; // Retry next tick
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * _Point;

// Entry prices WITH buffer
   double buyEntry  = NormalizeDouble(g_rangeHigh + InpEntryBuffer, _Digits);
   double sellEntry = NormalizeDouble(g_rangeLow - InpEntryBuffer, _Digits);

// SL at opposite range extreme (NOT including buffer - SL stays at range boundary)
   double buySL     = NormalizeDouble(g_rangeLow, _Digits);
   double sellSL    = NormalizeDouble(g_rangeHigh, _Digits);

// Risk = entry to SL (includes buffer, so slightly larger than pure range)
   double buyRisk   = buyEntry - buySL;
   double sellRisk  = sellSL - sellEntry;

// TP based on R multiple of actual risk
   double buyTP     = NormalizeDouble(buyEntry + InpTPMultiplier * buyRisk, _Digits);
   double sellTP    = NormalizeDouble(sellEntry - InpTPMultiplier * sellRisk, _Digits);

   bool placedAny = false;

//--- Place BUY STOP (only if trend allows or no trend filter)
   bool allowBuy = true;
   if(InpUseTrendFilter && g_trendDirection == -1)
      allowBuy = false; // Don't buy in bearish trend
   if(InpUseTrendFilter && g_trendDirection == 0)
      allowBuy = false; // Don't buy in neutral/mixed trend

   if(allowBuy && buyEntry > ask + minDist)
     {
      bool ok = trade.BuyStop(InpLotSize, buyEntry, _Symbol, buySL, buyTP,
                              ORDER_TIME_GTC, 0, "GRB Buy");
      if(ok)
        {
         g_buyTicket = trade.ResultOrder();
         Print("BUY STOP #", g_buyTicket,
               " Entry=", DoubleToString(buyEntry, _Digits),
               " SL=", DoubleToString(buySL, _Digits),
               " TP=", DoubleToString(buyTP, _Digits),
               " Risk=", DoubleToString(buyRisk / _Point, 0), "pts");
         placedAny = true;
        }
      else
         Print("FAILED BuyStop. Err=", GetLastError());
     }
   else if(!allowBuy)
      Print("BUY filtered by trend (direction=", g_trendDirection, ")");

//--- Place SELL STOP (only if trend allows or no trend filter)
   bool allowSell = true;
   if(InpUseTrendFilter && g_trendDirection == 1)
      allowSell = false; // Don't sell in bullish trend
   if(InpUseTrendFilter && g_trendDirection == 0)
      allowSell = false; // Don't sell in neutral/mixed trend

   if(allowSell && sellEntry < bid - minDist)
     {
      bool ok = trade.SellStop(InpLotSize, sellEntry, _Symbol, sellSL, sellTP,
                               ORDER_TIME_GTC, 0, "GRB Sell");
      if(ok)
        {
         g_sellTicket = trade.ResultOrder();
         Print("SELL STOP #", g_sellTicket,
               " Entry=", DoubleToString(sellEntry, _Digits),
               " SL=", DoubleToString(sellSL, _Digits),
               " TP=", DoubleToString(sellTP, _Digits),
               " Risk=", DoubleToString(sellRisk / _Point, 0), "pts");
         placedAny = true;
        }
      else
         Print("FAILED SellStop. Err=", GetLastError());
     }
   else if(!allowSell)
      Print("SELL filtered by trend (direction=", g_trendDirection, ")");

   if(placedAny)
      g_state = STATE_ORDERS_PLACED;
   else
     {
      Print("No orders placed (filtered or price already broke range).");
      g_state = STATE_DONE_FOR_DAY;
     }
  }

//+------------------------------------------------------------------+
//| OCO Logic                                                         |
//+------------------------------------------------------------------+
void CheckOCO()
  {
   bool buyPending  = (g_buyTicket > 0)  && OrderExists(g_buyTicket);
   bool sellPending = (g_sellTicket > 0) && OrderExists(g_sellTicket);

   if(g_buyTicket > 0 && !buyPending)
     {
      if(HasOpenPosition())
        {
         if(sellPending)
            trade.OrderDelete(g_sellTicket);
         g_state = STATE_TRADE_ACTIVE;
         Print("BUY triggered -> SELL cancelled.");
         return;
        }
     }

   if(g_sellTicket > 0 && !sellPending)
     {
      if(HasOpenPosition())
        {
         if(buyPending)
            trade.OrderDelete(g_buyTicket);
         g_state = STATE_TRADE_ACTIVE;
         Print("SELL triggered -> BUY cancelled.");
         return;
        }
     }

   if(!buyPending && !sellPending && !HasOpenPosition())
     {
      g_state = STATE_DONE_FOR_DAY;
     }
  }

//+------------------------------------------------------------------+
//| Manage open trade: partial close, BE, trailing                    |
//+------------------------------------------------------------------+
void ManageOpenTrade()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      double riskSize = MathAbs(openPrice - sl);
      if(riskSize < _Point)
         continue;

      if(posType == POSITION_TYPE_BUY)
        {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDist = currentBid - openPrice;
         double profitR    = profitDist / riskSize;

         //--- Partial close at 1R
         if(InpUsePartialClose && !g_partialClosed && profitR >= 1.0)
           {
            double closeVol = NormalizeVolume(volume * InpPartialPercent / 100.0);
            if(closeVol > 0 && closeVol < volume)
              {
               if(trade.PositionClosePartial(ticket, closeVol))
                 {
                  Print("PARTIAL CLOSE BUY ", DoubleToString(InpPartialPercent, 0),
                        "% at 1R. Closed=", DoubleToString(closeVol, 2));
                  g_partialClosed = true;
                 }
              }
           }

         //--- Break-even at 1R
         if(InpUseBreakEven && !g_breakEvenApplied && profitR >= 1.0 && sl < openPrice)
           {
            double newSL = NormalizeDouble(openPrice, _Digits);
            if(trade.PositionModify(ticket, newSL, tp))
              {
               Print("BE BUY #", ticket, " SL->", DoubleToString(newSL, _Digits));
               g_breakEvenApplied = true;
              }
           }

         //--- Trailing stop (after BE is set)
         if(InpUseTrailingStop && g_breakEvenApplied && profitR >= 1.5)
           {
            double trailDist = InpTrailingRMultiple * riskSize;
            double trailSL = NormalizeDouble(currentBid - trailDist, _Digits);
            if(trailSL > sl && trailSL > openPrice)
              {
               if(trade.PositionModify(ticket, trailSL, tp))
                  Print("TRAIL BUY SL->", DoubleToString(trailSL, _Digits));
              }
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDist = openPrice - currentAsk;
         double profitR    = profitDist / riskSize;

         //--- Partial close at 1R
         if(InpUsePartialClose && !g_partialClosed && profitR >= 1.0)
           {
            double closeVol = NormalizeVolume(volume * InpPartialPercent / 100.0);
            if(closeVol > 0 && closeVol < volume)
              {
               if(trade.PositionClosePartial(ticket, closeVol))
                 {
                  Print("PARTIAL CLOSE SELL ", DoubleToString(InpPartialPercent, 0),
                        "% at 1R. Closed=", DoubleToString(closeVol, 2));
                  g_partialClosed = true;
                 }
              }
           }

         //--- Break-even at 1R
         if(InpUseBreakEven && !g_breakEvenApplied && profitR >= 1.0 && sl > openPrice)
           {
            double newSL = NormalizeDouble(openPrice, _Digits);
            if(trade.PositionModify(ticket, newSL, tp))
              {
               Print("BE SELL #", ticket, " SL->", DoubleToString(newSL, _Digits));
               g_breakEvenApplied = true;
              }
           }

         //--- Trailing stop (after BE is set)
         if(InpUseTrailingStop && g_breakEvenApplied && profitR >= 1.5)
           {
            double trailDist = InpTrailingRMultiple * riskSize;
            double trailSL = NormalizeDouble(currentAsk + trailDist, _Digits);
            if(trailSL < sl && trailSL < openPrice)
              {
               if(trade.PositionModify(ticket, trailSL, tp))
                  Print("TRAIL SELL SL->", DoubleToString(trailSL, _Digits));
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Normalize volume to broker step                                   |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepVol <= 0)
      stepVol = 0.01;

   volume = MathFloor(volume / stepVol) * stepVol;

   if(volume < minVol)
      return 0; // Can't trade below minimum
   if(volume > maxVol)
      volume = maxVol;

   return NormalizeDouble(volume, 2);
  }

//+------------------------------------------------------------------+
//| Check if pending order exists                                     |
//+------------------------------------------------------------------+
bool OrderExists(ulong ticket)
  {
   if(ticket == 0)
      return false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == ticket)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check if we have an open position                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Delete all pending orders with our magic                          |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber &&
         OrderGetString(ORDER_SYMBOL) == _Symbol)
        {
         trade.OrderDelete(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Cleanup pending orders (on new day)                               |
//+------------------------------------------------------------------+
void CleanupPendingOrders()
  {
   DeleteAllPendingOrders();
  }

//+------------------------------------------------------------------+
//| NY Time to Broker Time conversion                                 |
//+------------------------------------------------------------------+
datetime NYTimeToBroker(int nyHour, int nyMinute)
  {
   MqlDateTime dt;
   TimeCurrent(dt);

   bool isDST = IsUSDST(dt.year, dt.mon, dt.day);
   int nyToUTC = isDST ? 4 : 5;
   int totalShiftHours = nyToUTC + InpBrokerGMTOffset;

   dt.hour = nyHour + totalShiftHours;
   dt.min  = nyMinute;
   dt.sec  = 0;

   while(dt.hour >= 24)
      dt.hour -= 24;

   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| US DST detection                                                  |
//+------------------------------------------------------------------+
bool IsUSDST(int year, int month, int day)
  {
   if(month > 3 && month < 11)
      return true;
   if(month < 3 || month > 11)
      return false;

   if(month == 3)
     {
      int dow1 = DayOfWeekCalc(year, 3, 1);
      int firstSunday = (dow1 == 0) ? 1 : (8 - dow1);
      int secondSunday = firstSunday + 7;
      return (day >= secondSunday);
     }

   if(month == 11)
     {
      int dow1 = DayOfWeekCalc(year, 11, 1);
      int firstSunday = (dow1 == 0) ? 1 : (8 - dow1);
      return (day < firstSunday);
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Zeller day of week                                                |
//+------------------------------------------------------------------+
int DayOfWeekCalc(int year, int month, int day)
  {
   if(month < 3)
     {
      month += 12;
      year--;
     }
   int k = year % 100;
   int j = year / 100;
   int h = (day + (13 * (month + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7;
   int dow = ((h + 6) % 7);
   return dow;
  }

//+------------------------------------------------------------------+
//| Draw range box on chart                                           |
//+------------------------------------------------------------------+
void DrawRangeBox()
  {
   string objName = g_objPrefix + TimeToString(g_rangeStartTime, TIME_DATE|TIME_MINUTES);
   ObjectDelete(0, objName);

   if(!ObjectCreate(0, objName, OBJ_RECTANGLE, 0,
                    g_rangeStartTime, g_rangeHigh,
                    g_rangeEndTime, g_rangeLow))
      return;

   ObjectSetInteger(0, objName, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, InpRangeLineWidth);
   ObjectSetInteger(0, objName, OBJPROP_FILL, InpFillRange);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, objName, OBJPROP_TOOLTIP,
                   "Range: " + DoubleToString(g_rangeHigh, _Digits) +
                   " - " + DoubleToString(g_rangeLow, _Digits) +
                   " | " + DoubleToString(g_rangeSize / _Point, 0) + "pts" +
                   " | Trend=" + IntegerToString(g_trendDirection));
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
