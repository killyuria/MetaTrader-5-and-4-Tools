//+------------------------------------------------------------------+
//|                                          GoldRangeBreakout.mq5   |
//|                         Gold Range Breakout Strategy              |
//|                         Timeframe: 5 min - XAUUSD                |
//+------------------------------------------------------------------+
#property copyright   "Gold Range Breakout Bot"
#property link        ""
#property version     "2.00"
#property strict
#property description "Range breakout strategy for Gold (XAUUSD)."
#property description "Marks a range during a configurable NY session window,"
#property description "places Buy Stop / Sell Stop at range extremes,"
#property description "OCO logic, optional Break-Even, and configurable TP in R multiples."

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

input group "=== Trade Settings ==="
input double InpLotSize          = 0.10; // Lot Size
input double InpTPMultiplier     = 3.0;  // Take Profit (R multiples)
input bool   InpUseBreakEven     = true; // Enable Break-Even at 1:1
input int    InpDeletePendingHour   = 10; // Hour (NY) to delete unfilled pending orders
input int    InpDeletePendingMinute = 0;  // Minute to delete unfilled pending orders
input int    InpMaxSpreadPoints  = 50;   // Max Spread to Place Orders (points, 0=disabled)

input group "=== Visual Settings ==="
input color  InpRangeColor       = clrDodgerBlue; // Range Box Color
input int    InpRangeLineWidth   = 2;             // Range Box Border Width
input bool   InpFillRange        = true;          // Fill Range Box
input bool   InpShowRange        = true;          // Show Range Box on Chart

input group "=== General ==="
input ulong  InpMagicNumber      = 777777; // Magic Number
input int    InpSlippage         = 30;     // Slippage (points)

//+------------------------------------------------------------------+
//| Enums for state machine                                           |
//+------------------------------------------------------------------+
enum ENUM_RANGE_STATE
  {
   STATE_WAITING_FOR_RANGE,     // Waiting for range window to start
   STATE_BUILDING_RANGE,        // Inside range window, collecting H/L
   STATE_RANGE_COMPLETE,        // Range formed, need to place orders
   STATE_ORDERS_PLACED,         // Pending orders placed, waiting for trigger
   STATE_TRADE_ACTIVE,          // One order triggered, managing position
   STATE_DONE_FOR_DAY           // Done for today
  };

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade            trade;
ENUM_RANGE_STATE  g_state;
double            g_rangeHigh;
double            g_rangeLow;
datetime          g_rangeStartTime;
datetime          g_rangeEndTime;
ulong             g_buyTicket;
ulong             g_sellTicket;
bool              g_breakEvenApplied;
int               g_lastDay;
string            g_objPrefix;

//+------------------------------------------------------------------+
//| Convert NY time (hour:minute) to broker server time for today     |
//| Uses a fixed broker GMT offset (input) instead of TimeGMT()      |
//| which does NOT work in the strategy tester.                       |
//|                                                                   |
//| NY is UTC-5 (EST) or UTC-4 (EDT).                                |
//| Formula: broker_time = ny_time + ny_to_utc + utc_to_broker       |
//|        = ny_time + (5 or 4) + InpBrokerGMTOffset                 |
//+------------------------------------------------------------------+
datetime NYTimeToBroker(int nyHour, int nyMinute)
  {
   MqlDateTime dt;
   TimeCurrent(dt);

// Determine if US DST is active for the current broker date
   bool isDST = IsUSDST(dt.year, dt.mon, dt.day);

// NY to UTC offset: +5 in winter (EST), +4 in summer (EDT)
   int nyToUTC = isDST ? 4 : 5;

// Total shift from NY to broker
   int totalShiftHours = nyToUTC + InpBrokerGMTOffset;

// Build broker datetime
   dt.hour = nyHour + totalShiftHours;
   dt.min  = nyMinute;
   dt.sec  = 0;

// Handle hour overflow (next day)
   while(dt.hour >= 24)
     {
      dt.hour -= 24;
      // We don't adjust the day because the range should be same-day
      // If broker is far ahead, this naturally works
     }

   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Determine if US DST is active (Second Sun Mar - First Sun Nov)    |
//+------------------------------------------------------------------+
bool IsUSDST(int year, int month, int day)
  {
   if(month > 3 && month < 11)
      return true;
   if(month < 3 || month > 11)
      return false;

   if(month == 3)
     {
      // Second Sunday of March
      // Find day-of-week of March 1st
      int dow1 = DayOfWeek(year, 3, 1);
      // First Sunday: if March 1 is Sunday, it's day 1. Otherwise 8-dow1
      int firstSunday = (dow1 == 0) ? 1 : (8 - dow1);
      int secondSunday = firstSunday + 7;
      return (day >= secondSunday);
     }

   if(month == 11)
     {
      // First Sunday of November
      int dow1 = DayOfWeek(year, 11, 1);
      int firstSunday = (dow1 == 0) ? 1 : (8 - dow1);
      return (day < firstSunday);
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Zeller-based day of week (0=Sunday, 1=Monday, ..., 6=Saturday)   |
//+------------------------------------------------------------------+
int DayOfWeek(int year, int month, int day)
  {
   if(month < 3)
     {
      month += 12;
      year--;
     }
   int k = year % 100;
   int j = year / 100;
   int h = (day + (13 * (month + 1)) / 5 + k + k / 4 + j / 4 - 2 * j) % 7;
   // Zeller: h=0 is Saturday, h=1 is Sunday, etc.
   int dow = ((h + 6) % 7); // Convert: 0=Sunday
   return dow;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_objPrefix = "GRB_" + IntegerToString(InpMagicNumber) + "_";

   ResetDailyState();
   g_lastDay = -1;

   Print("GoldRangeBreakout v2.0 initialized. Magic=", InpMagicNumber,
         " BrokerGMT=", InpBrokerGMTOffset);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(reason == REASON_REMOVE || reason == REASON_RECOMPILE)
     {
      ObjectsDeleteAll(0, g_objPrefix);
      ChartRedraw(0);
     }
  }

//+------------------------------------------------------------------+
//| Reset daily state variables                                       |
//+------------------------------------------------------------------+
void ResetDailyState()
  {
   g_state            = STATE_WAITING_FOR_RANGE;
   g_rangeHigh        = 0;
   g_rangeLow         = 0;
   g_rangeStartTime   = 0;
   g_rangeEndTime     = 0;
   g_buyTicket        = 0;
   g_sellTicket       = 0;
   g_breakEvenApplied = false;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();
   MqlDateTime dtNow;
   TimeCurrent(dtNow);

//--- New day detection: reset state
   if(dtNow.day != g_lastDay)
     {
      // Clean up any leftover pending orders from yesterday
      CleanupPendingOrders();
      g_lastDay = dtNow.day;
      ResetDailyState();
     }

//--- Calculate today's time windows in broker time
   datetime rangeStart   = NYTimeToBroker(InpRangeStartHour, InpRangeStartMinute);
   datetime rangeEnd     = NYTimeToBroker(InpRangeEndHour, InpRangeEndMinute);
   datetime deleteTime   = NYTimeToBroker(InpDeletePendingHour, InpDeletePendingMinute);

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
            Print("Range window started. Collecting High/Low...");
           }
         break;

      case STATE_BUILDING_RANGE:
         // Keep updating range with current tick
         UpdateRangeFromTick();

         // Check if range window has ended
         if(now >= rangeEnd)
           {
            // Final scan of completed bars to be sure
            FinalizeRange();

            if(g_rangeHigh > 0 && g_rangeLow < DBL_MAX && g_rangeHigh > g_rangeLow)
              {
               g_state = STATE_RANGE_COMPLETE;
               Print("Range COMPLETE: High=", DoubleToString(g_rangeHigh, _Digits),
                     " Low=", DoubleToString(g_rangeLow, _Digits),
                     " Size=", DoubleToString((g_rangeHigh - g_rangeLow) / _Point, 0), " pts");

               if(InpShowRange)
                  DrawRangeBox();
              }
            else
              {
               Print("Range invalid or zero. Skipping today.");
               g_state = STATE_DONE_FOR_DAY;
              }
           }
         break;

      case STATE_RANGE_COMPLETE:
         PlacePendingOrders();
         break;

      case STATE_ORDERS_PLACED:
         // Check if one order triggered -> cancel the other
         CheckOCO();

         // Delete unfilled pending orders after cutoff time
         if(now >= deleteTime)
           {
            Print("Cutoff time reached. Deleting unfilled pending orders.");
            DeleteAllPendingOrders();
            g_state = STATE_DONE_FOR_DAY;
           }
         break;

      case STATE_TRADE_ACTIVE:
         // Manage break-even
         if(InpUseBreakEven && !g_breakEvenApplied)
            CheckBreakEven();

         // Check if position is still open
         if(!HasOpenPosition())
           {
            Print("Position closed. Done for today.");
            g_state = STATE_DONE_FOR_DAY;
           }
         break;

      case STATE_DONE_FOR_DAY:
         // Nothing to do
         break;
     }
  }

//+------------------------------------------------------------------+
//| Update range from current tick data                               |
//+------------------------------------------------------------------+
void UpdateRangeFromTick()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

// Use high/low of current forming bar
   double barHigh = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double barLow  = iLow(_Symbol, PERIOD_CURRENT, 0);

   if(barHigh > g_rangeHigh)
      g_rangeHigh = barHigh;
   if(barLow < g_rangeLow)
      g_rangeLow = barLow;
  }

//+------------------------------------------------------------------+
//| Final complete scan of all bars within the range window           |
//+------------------------------------------------------------------+
void FinalizeRange()
  {
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   for(int i = 0; i < bars; i++)
     {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, i);

      // Stop scanning past the range start
      if(barTime < g_rangeStartTime)
         break;

      // Only include bars within the range window
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

// Normalize
   g_rangeHigh = NormalizeDouble(g_rangeHigh, _Digits);
   g_rangeLow  = NormalizeDouble(g_rangeLow, _Digits);
  }

//+------------------------------------------------------------------+
//| Place Buy Stop and Sell Stop at range extremes                    |
//+------------------------------------------------------------------+
void PlacePendingOrders()
  {
   double rangeSize = g_rangeHigh - g_rangeLow;

// Minimum range validation (at least 50 points for gold)
   if(rangeSize < _Point * 10)
     {
      Print("Range too small: ", DoubleToString(rangeSize / _Point, 0),
            " pts. Skipping today.");
      g_state = STATE_DONE_FOR_DAY;
      return;
     }

// Check spread
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
        {
         // Don't change state, retry next tick
         return;
        }
     }

// Prices for Buy Stop
   double buyEntry  = NormalizeDouble(g_rangeHigh, _Digits);
   double buySL     = NormalizeDouble(g_rangeLow, _Digits);
   double buyTP     = NormalizeDouble(buyEntry + InpTPMultiplier * rangeSize, _Digits);

// Prices for Sell Stop
   double sellEntry = NormalizeDouble(g_rangeLow, _Digits);
   double sellSL    = NormalizeDouble(g_rangeHigh, _Digits);
   double sellTP    = NormalizeDouble(sellEntry - InpTPMultiplier * rangeSize, _Digits);

// Check minimum distance from current price (STOP_LEVEL)
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * _Point;

// Buy Stop must be ABOVE current ask
   if(buyEntry <= ask + minDist)
     {
      Print("Buy Stop entry ", DoubleToString(buyEntry, _Digits),
            " too close to ask ", DoubleToString(ask, _Digits),
            ". Price already broke above range. Skipping buy.");
     }
   else
     {
      bool buyResult = trade.BuyStop(InpLotSize, buyEntry, _Symbol, buySL, buyTP,
                                     ORDER_TIME_GTC, 0, "GRB Buy");
      if(buyResult)
        {
         g_buyTicket = trade.ResultOrder();
         Print("BUY STOP placed #", g_buyTicket,
               " Entry=", DoubleToString(buyEntry, _Digits),
               " SL=", DoubleToString(buySL, _Digits),
               " TP=", DoubleToString(buyTP, _Digits));
        }
      else
        {
         Print("FAILED Buy Stop. Error=", GetLastError(),
               " Entry=", DoubleToString(buyEntry, _Digits),
               " Ask=", DoubleToString(ask, _Digits));
        }
     }

// Sell Stop must be BELOW current bid
   if(sellEntry >= bid - minDist)
     {
      Print("Sell Stop entry ", DoubleToString(sellEntry, _Digits),
            " too close to bid ", DoubleToString(bid, _Digits),
            ". Price already broke below range. Skipping sell.");
     }
   else
     {
      bool sellResult = trade.SellStop(InpLotSize, sellEntry, _Symbol, sellSL, sellTP,
                                       ORDER_TIME_GTC, 0, "GRB Sell");
      if(sellResult)
        {
         g_sellTicket = trade.ResultOrder();
         Print("SELL STOP placed #", g_sellTicket,
               " Entry=", DoubleToString(sellEntry, _Digits),
               " SL=", DoubleToString(sellSL, _Digits),
               " TP=", DoubleToString(sellTP, _Digits));
        }
      else
        {
         Print("FAILED Sell Stop. Error=", GetLastError(),
               " Entry=", DoubleToString(sellEntry, _Digits),
               " Bid=", DoubleToString(bid, _Digits));
        }
     }

// If at least one order was placed, move to next state
   if(g_buyTicket > 0 || g_sellTicket > 0)
     {
      g_state = STATE_ORDERS_PLACED;
     }
   else
     {
      Print("No orders placed. Price may have already broken the range.");
      g_state = STATE_DONE_FOR_DAY;
     }
  }

//+------------------------------------------------------------------+
//| OCO: When one order triggers, cancel the other                    |
//+------------------------------------------------------------------+
void CheckOCO()
  {
   bool buyPending  = (g_buyTicket > 0)  && OrderExists(g_buyTicket);
   bool sellPending = (g_sellTicket > 0) && OrderExists(g_sellTicket);

// If buy order is no longer pending
   if(g_buyTicket > 0 && !buyPending)
     {
      // It was triggered or expired/deleted
      if(HasOpenPosition())
        {
         Print("BUY triggered. Cancelling SELL pending.");
         // Cancel sell stop
         if(sellPending)
            trade.OrderDelete(g_sellTicket);
         g_state = STATE_TRADE_ACTIVE;
         return;
        }
     }

// If sell order is no longer pending
   if(g_sellTicket > 0 && !sellPending)
     {
      if(HasOpenPosition())
        {
         Print("SELL triggered. Cancelling BUY pending.");
         // Cancel buy stop
         if(buyPending)
            trade.OrderDelete(g_buyTicket);
         g_state = STATE_TRADE_ACTIVE;
         return;
        }
     }

// If both pending orders are gone and no position, done for day
   if(!buyPending && !sellPending && !HasOpenPosition())
     {
      Print("Both pending orders gone with no position. Done for day.");
      g_state = STATE_DONE_FOR_DAY;
     }
  }

//+------------------------------------------------------------------+
//| Check if a pending order still exists                             |
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
//| Check if we have an open position with our magic number           |
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
//| Move SL to Break-Even when price reaches 1:1 R                   |
//+------------------------------------------------------------------+
void CheckBreakEven()
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
      long   posType   = PositionGetInteger(POSITION_TYPE);

      double riskSize = MathAbs(openPrice - sl);
      if(riskSize < _Point)
         continue; // Safety check

      if(posType == POSITION_TYPE_BUY)
        {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         // Price has moved at least 1R in favor
         if(currentBid >= openPrice + riskSize && sl < openPrice)
           {
            double newSL = NormalizeDouble(openPrice, _Digits);
            if(trade.PositionModify(ticket, newSL, tp))
              {
               Print("BREAK-EVEN BUY #", ticket,
                     " SL moved to ", DoubleToString(newSL, _Digits));
               g_breakEvenApplied = true;
              }
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         // Price has moved at least 1R in favor
         if(currentAsk <= openPrice - riskSize && sl > openPrice)
           {
            double newSL = NormalizeDouble(openPrice, _Digits);
            if(trade.PositionModify(ticket, newSL, tp))
              {
               Print("BREAK-EVEN SELL #", ticket,
                     " SL moved to ", DoubleToString(newSL, _Digits));
               g_breakEvenApplied = true;
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Delete all pending orders with our magic number                   |
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
         Print("Deleted pending order #", ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Cleanup any leftover pending orders (called on new day)           |
//+------------------------------------------------------------------+
void CleanupPendingOrders()
  {
   DeleteAllPendingOrders();
  }

//+------------------------------------------------------------------+
//| Draw the range box on the chart                                   |
//+------------------------------------------------------------------+
void DrawRangeBox()
  {
   string objName = g_objPrefix + TimeToString(g_rangeStartTime, TIME_DATE|TIME_MINUTES);

   ObjectDelete(0, objName);

   if(!ObjectCreate(0, objName, OBJ_RECTANGLE, 0,
                    g_rangeStartTime, g_rangeHigh,
                    g_rangeEndTime, g_rangeLow))
     {
      Print("Failed to create range box. Error=", GetLastError());
      return;
     }

   ObjectSetInteger(0, objName, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, InpRangeLineWidth);
   ObjectSetInteger(0, objName, OBJPROP_FILL, InpFillRange);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, objName, OBJPROP_TOOLTIP,
                   "Range: " + DoubleToString(g_rangeHigh, _Digits) +
                   " - " + DoubleToString(g_rangeLow, _Digits) +
                   " | Size: " + DoubleToString((g_rangeHigh - g_rangeLow) / _Point, 0) + " pts");

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
