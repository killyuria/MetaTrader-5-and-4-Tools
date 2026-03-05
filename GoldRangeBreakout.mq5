//+------------------------------------------------------------------+
//|                                          GoldRangeBreakout.mq5   |
//|                         Gold Range Breakout Strategy              |
//|                         Timeframe: 5 min - XAUUSD                |
//+------------------------------------------------------------------+
#property copyright   "Gold Range Breakout Bot"
#property link        ""
#property version     "1.00"
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

input group "=== Trade Settings ==="
input double InpLotSize          = 0.10; // Lot Size
input double InpTPMultiplier     = 3.0;  // Take Profit (R multiples)
input bool   InpUseBreakEven     = true; // Enable Break-Even at 1:1
input int    InpOrderExpMinutes  = 120;  // Pending Order Expiration (minutes, 0=no expiry)
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
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
double         g_rangeHigh;
double         g_rangeLow;
datetime       g_rangeStartTime;
datetime       g_rangeEndTime;
bool           g_rangeFormed;
bool           g_ordersPlaced;
bool           g_buyTriggered;
bool           g_sellTriggered;
bool           g_breakEvenApplied;
ulong          g_buyTicket;
ulong          g_sellTicket;
datetime       g_lastRangeDate;
string         g_objPrefix;

//+------------------------------------------------------------------+
//| Get the broker's UTC offset for NY time conversion                |
//+------------------------------------------------------------------+
int GetNYOffsetSeconds()
  {
// New York is UTC-5 (EST) or UTC-4 (EDT).
// We calculate the offset from broker server time to NY time.
// This uses a simplified approach: broker time is assumed UTC+2/+3 (common for forex brokers).
// For accurate results, we detect DST for NY.

   MqlDateTime dt;
   TimeGMT(dt);

   int month = dt.mon;
   int day   = dt.day;
   int dow   = dt.day_of_week;

// US DST: Second Sunday of March to First Sunday of November
   bool nyDST = false;
   if(month > 3 && month < 11)
      nyDST = true;
   else
      if(month == 3)
        {
         // Second Sunday: find the day
         int secondSunday = (14 - dow + dt.day_of_week) ;
         // Simplified: if past March 14, likely DST
         if(day >= 14)
            nyDST = true;
        }
      else
         if(month == 11)
           {
            // First Sunday
            if(day < 7 && dow != 0)
               nyDST = true;
            if(day == 1 && dow == 0)
               nyDST = false;
           }

   int nyOffsetFromUTC = nyDST ? -4 : -5; // NY offset from UTC in hours

// Broker offset from UTC: difference between TimeCurrent and TimeGMT
   int brokerOffsetSec = (int)(TimeCurrent() - TimeGMT());

// To convert NY time to broker time: broker_time = ny_time - nyOffset + brokerOffset
// So: ny_hours_in_broker = ny_hour - nyOffsetFromUTC*3600 + brokerOffsetSec
// Return the total shift to ADD to NY time to get broker time
   return (-nyOffsetFromUTC * 3600 + brokerOffsetSec);
  }

//+------------------------------------------------------------------+
//| Convert NY hour:minute to broker server datetime for today        |
//+------------------------------------------------------------------+
datetime NYTimeToBroker(int nyHour, int nyMinute)
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime todayStart = StructToTime(dt);

   int nySeconds = nyHour * 3600 + nyMinute * 60;
   int offsetSec = GetNYOffsetSeconds();

   return todayStart + nySeconds + offsetSec;
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
   g_lastRangeDate = 0;

   Print("GoldRangeBreakout EA initialized. Magic=", InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
// Optionally remove visual objects
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
   g_rangeHigh      = -DBL_MAX;
   g_rangeLow       = DBL_MAX;
   g_rangeStartTime = 0;
   g_rangeEndTime   = 0;
   g_rangeFormed    = false;
   g_ordersPlaced   = false;
   g_buyTriggered   = false;
   g_sellTriggered  = false;
   g_breakEvenApplied = false;
   g_buyTicket      = 0;
   g_sellTicket     = 0;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

// Calculate today's range window in broker time
   datetime rangeStart = NYTimeToBroker(InpRangeStartHour, InpRangeStartMinute);
   datetime rangeEnd   = NYTimeToBroker(InpRangeEndHour, InpRangeEndMinute);

// Check for new day reset
   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   datetime today;
   MqlDateTime dtToday;
   dtToday.year  = dtNow.year;
   dtToday.mon   = dtNow.mon;
   dtToday.day   = dtNow.day;
   dtToday.hour  = 0;
   dtToday.min   = 0;
   dtToday.sec   = 0;
   dtToday.day_of_week  = dtNow.day_of_week;
   dtToday.day_of_year  = dtNow.day_of_year;
   today = StructToTime(dtToday);

   if(g_lastRangeDate != today)
     {
      g_lastRangeDate = today;
      ResetDailyState();
     }

//--- Phase 1: Build the range during the time window
   if(now >= rangeStart && now < rangeEnd && !g_rangeFormed)
     {
      g_rangeStartTime = rangeStart;
      g_rangeEndTime   = rangeEnd;
      UpdateRange();
     }

//--- Phase 2: Range is complete, place pending orders
   if(now >= rangeEnd && !g_rangeFormed && g_rangeLow < DBL_MAX && g_rangeHigh > -DBL_MAX)
     {
      g_rangeFormed = true;

      // Draw range box
      if(InpShowRange)
         DrawRangeBox();

      Print("Range formed: High=", DoubleToString(g_rangeHigh, _Digits),
            " Low=", DoubleToString(g_rangeLow, _Digits));
     }

//--- Phase 3: Place pending stop orders once range is confirmed
   if(g_rangeFormed && !g_ordersPlaced)
     {
      PlacePendingOrders();
     }

//--- Phase 4: OCO - cancel opposite order when one triggers
   if(g_ordersPlaced && (!g_buyTriggered || !g_sellTriggered))
     {
      CheckOCO();
     }

//--- Phase 5: Break-Even management
   if(InpUseBreakEven && !g_breakEvenApplied)
     {
      CheckBreakEven();
     }
  }

//+------------------------------------------------------------------+
//| Update range high and low from candles within the time window     |
//+------------------------------------------------------------------+
void UpdateRange()
  {
   double high = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double low  = iLow(_Symbol, PERIOD_CURRENT, 0);

   if(high > g_rangeHigh)
      g_rangeHigh = high;
   if(low < g_rangeLow)
      g_rangeLow = low;

// Also scan completed bars within the range window
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   for(int i = 1; i < bars; i++)
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
  }

//+------------------------------------------------------------------+
//| Place Buy Stop and Sell Stop at range extremes                    |
//+------------------------------------------------------------------+
void PlacePendingOrders()
  {
// Validate range
   double rangeSize = g_rangeHigh - g_rangeLow;
   if(rangeSize <= 0 || rangeSize < _Point * 10)
     {
      Print("Range too small, skipping orders. Range=", DoubleToString(rangeSize, _Digits));
      return;
     }

// Check spread
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
        {
         Print("Spread too high: ", spread, " > ", InpMaxSpreadPoints, ". Retrying next tick.");
         return;
        }
     }

// Calculate prices
   double buyEntry  = g_rangeHigh;  // Buy Stop at range high
   double buySL     = g_rangeLow;   // SL at range low
   double buyTP     = NormalizeDouble(buyEntry + InpTPMultiplier * rangeSize, _Digits); // TP = entry + R * range

   double sellEntry = g_rangeLow;   // Sell Stop at range low
   double sellSL    = g_rangeHigh;  // SL at range high
   double sellTP    = NormalizeDouble(sellEntry - InpTPMultiplier * rangeSize, _Digits); // TP = entry - R * range

// Normalize
   buyEntry  = NormalizeDouble(buyEntry, _Digits);
   buySL     = NormalizeDouble(buySL, _Digits);
   sellEntry = NormalizeDouble(sellEntry, _Digits);
   sellSL    = NormalizeDouble(sellSL, _Digits);

// Expiration
   ENUM_ORDER_TYPE_TIME expType = ORDER_TIME_GTC;
   datetime expiration = 0;
   if(InpOrderExpMinutes > 0)
     {
      expiration = TimeCurrent() + InpOrderExpMinutes * 60;
      expType = ORDER_TIME_SPECIFIED;
     }

// Place Buy Stop
   bool buyResult = trade.BuyStop(InpLotSize, buyEntry, _Symbol, buySL, buyTP,
                                  expType, expiration, "GRB Buy Stop");
   if(buyResult)
     {
      g_buyTicket = trade.ResultOrder();
      Print("Buy Stop placed: Entry=", DoubleToString(buyEntry, _Digits),
            " SL=", DoubleToString(buySL, _Digits),
            " TP=", DoubleToString(buyTP, _Digits),
            " Ticket=", g_buyTicket);
     }
   else
     {
      Print("Failed to place Buy Stop. Error=", GetLastError());
      return;
     }

// Place Sell Stop
   bool sellResult = trade.SellStop(InpLotSize, sellEntry, _Symbol, sellSL, sellTP,
                                    expType, expiration, "GRB Sell Stop");
   if(sellResult)
     {
      g_sellTicket = trade.ResultOrder();
      Print("Sell Stop placed: Entry=", DoubleToString(sellEntry, _Digits),
            " SL=", DoubleToString(sellSL, _Digits),
            " TP=", DoubleToString(sellTP, _Digits),
            " Ticket=", g_sellTicket);
     }
   else
     {
      Print("Failed to place Sell Stop. Error=", GetLastError());
      // Delete the buy stop since sell failed
      trade.OrderDelete(g_buyTicket);
      g_buyTicket = 0;
      return;
     }

   g_ordersPlaced = true;
  }

//+------------------------------------------------------------------+
//| Check if one pending order was triggered and cancel the other     |
//+------------------------------------------------------------------+
void CheckOCO()
  {
// Check if buy stop was triggered (became a position)
   if(!g_buyTriggered && g_buyTicket > 0)
     {
      if(!OrderExists(g_buyTicket))
        {
         // Order no longer pending - check if it became a position
         if(PositionExistsByMagic(POSITION_TYPE_BUY))
           {
            g_buyTriggered = true;
            Print("Buy Stop triggered. Cancelling Sell Stop.");

            // Cancel the opposite sell stop
            if(g_sellTicket > 0 && OrderExists(g_sellTicket))
              {
               trade.OrderDelete(g_sellTicket);
               Print("Sell Stop cancelled. Ticket=", g_sellTicket);
              }
            g_sellTriggered = true; // Mark as handled
           }
        }
     }

// Check if sell stop was triggered
   if(!g_sellTriggered && g_sellTicket > 0)
     {
      if(!OrderExists(g_sellTicket))
        {
         if(PositionExistsByMagic(POSITION_TYPE_SELL))
           {
            g_sellTriggered = true;
            Print("Sell Stop triggered. Cancelling Buy Stop.");

            // Cancel the opposite buy stop
            if(g_buyTicket > 0 && OrderExists(g_buyTicket))
              {
               trade.OrderDelete(g_buyTicket);
               Print("Buy Stop cancelled. Ticket=", g_buyTicket);
              }
            g_buyTriggered = true; // Mark as handled
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Check if a pending order still exists                             |
//+------------------------------------------------------------------+
bool OrderExists(ulong ticket)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == ticket)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check if a position exists by magic number and type               |
//+------------------------------------------------------------------+
bool PositionExistsByMagic(ENUM_POSITION_TYPE posType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == posType)
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

      double rangeSize = MathAbs(openPrice - sl);
      double currentPrice;

      if(posType == POSITION_TYPE_BUY)
        {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         // Check if price has moved 1R in profit (1:1)
         if(currentPrice >= openPrice + rangeSize)
           {
            // Move SL to break-even (entry price)
            if(sl < openPrice)
              {
               double newSL = NormalizeDouble(openPrice, _Digits);
               if(trade.PositionModify(ticket, newSL, tp))
                 {
                  Print("Break-Even applied for BUY. Ticket=", ticket,
                        " New SL=", DoubleToString(newSL, _Digits));
                  g_breakEvenApplied = true;
                 }
              }
           }
        }
      else
         if(posType == POSITION_TYPE_SELL)
           {
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            // Check if price has moved 1R in profit (1:1)
            if(currentPrice <= openPrice - rangeSize)
              {
               // Move SL to break-even (entry price)
               if(sl > openPrice)
                 {
                  double newSL = NormalizeDouble(openPrice, _Digits);
                  if(trade.PositionModify(ticket, newSL, tp))
                    {
                     Print("Break-Even applied for SELL. Ticket=", ticket,
                           " New SL=", DoubleToString(newSL, _Digits));
                     g_breakEvenApplied = true;
                    }
                 }
              }
           }
     }
  }

//+------------------------------------------------------------------+
//| Draw the range box on the chart                                   |
//+------------------------------------------------------------------+
void DrawRangeBox()
  {
   string objName = g_objPrefix + TimeToString(g_rangeStartTime, TIME_DATE);

// Delete old object if it exists
   ObjectDelete(0, objName);

// Create rectangle
   if(!ObjectCreate(0, objName, OBJ_RECTANGLE, 0,
                    g_rangeStartTime, g_rangeHigh,
                    g_rangeEndTime, g_rangeLow))
     {
      Print("Failed to create range box. Error=", GetLastError());
      return;
     }

// Set properties
   ObjectSetInteger(0, objName, OBJPROP_COLOR, InpRangeColor);
   ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, InpRangeLineWidth);
   ObjectSetInteger(0, objName, OBJPROP_FILL, InpFillRange);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
   ObjectSetString(0, objName, OBJPROP_TOOLTIP,
                   "Range: " + DoubleToString(g_rangeHigh, _Digits) +
                   " - " + DoubleToString(g_rangeLow, _Digits) +
                   "\nSize: " + DoubleToString((g_rangeHigh - g_rangeLow) / _Point, 0) + " pts");

// Extend box visually a bit to the right for better visibility
   datetime extendedEnd = g_rangeEndTime + PeriodSeconds(PERIOD_M5) * 3;
   ObjectSetInteger(0, objName, OBJPROP_TIME, 1, extendedEnd);

   ChartRedraw(0);
   Print("Range box drawn: ", objName);
  }

//+------------------------------------------------------------------+
