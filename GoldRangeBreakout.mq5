//+------------------------------------------------------------------+
//|                                          GoldRangeBreakout.mq5   |
//|                         Gold Range Breakout Strategy v4.0         |
//|                         Timeframe: 5 min - XAUUSD                |
//+------------------------------------------------------------------+
#property copyright   "Gold Range Breakout Bot"
#property link        ""
#property version     "4.00"
#property strict
#property description "Range breakout strategy for Gold (XAUUSD) v4.0"
#property description "Session close, smart trailing, trend filter, buffer entry."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Range Time Settings (New York Time) ==="
input int    InpRangeStartHour   = 7;    // Range Start Hour (NY)
input int    InpRangeStartMinute = 30;   // Range Start Minute
input int    InpRangeEndHour     = 7;    // Range End Hour (NY)
input int    InpRangeEndMinute   = 45;   // Range End Minute
input int    InpBrokerGMTOffset  = 2;    // Broker GMT Offset (hours)

input group "=== Session Close ==="
input int    InpCloseHour        = 11;   // Close Positions Hour (NY) - end of morning session
input int    InpCloseMinute      = 0;    // Close Positions Minute
input int    InpDeletePendingHour   = 9; // Delete Unfilled Orders Hour (NY)
input int    InpDeletePendingMinute = 30; // Delete Unfilled Orders Minute

input group "=== Trade Settings ==="
input double InpLotSize          = 0.01; // Lot Size
input double InpTPMultiplier     = 3.0;  // Take Profit (R multiples)
input double InpEntryBuffer      = 0.50; // Entry Buffer (price units)
input int    InpMaxSpreadPoints  = 50;   // Max Spread (points, 0=disabled)

input group "=== Break-Even & Trailing ==="
input bool   InpUseBreakEven     = true; // Enable Break-Even
input double InpBETriggerR       = 1.0;  // BE Trigger (R multiples)
input double InpBELockR          = 0.3;  // BE Lock-in Profit (R multiples, 0=exact entry)
input bool   InpUseTrailingStop  = true; // Enable Trailing Stop
input double InpTrailStartR      = 1.0;  // Trail Activation (R multiples)
input double InpTrailDistR       = 0.5;  // Trail Distance (R multiples)

input group "=== Partial Close ==="
input bool   InpUsePartialClose  = false; // Enable Partial Close
input double InpPartialTriggerR  = 1.0;  // Partial Close Trigger (R)
input double InpPartialPercent   = 50.0; // Partial Close Percentage (%)

input group "=== Trend Filter ==="
input bool   InpUseTrendFilter   = true;  // Enable Trend Filter
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1; // Trend Timeframe
input int    InpEMAPeriod        = 200;   // EMA Period
input bool   InpOnlyTrendDir     = true;  // Only Trade Trend Direction (false=both if neutral)

input group "=== Range Size Filters ==="
input double InpMinRangePrice    = 1.00;  // Minimum Range (price units, e.g. $1.00)
input double InpMaxRangePrice    = 8.00;  // Maximum Range (price units, e.g. $8.00)

input group "=== Day of Week Filter ==="
input bool   InpTradeMonday      = true;  // Trade Monday
input bool   InpTradeTuesday     = true;  // Trade Tuesday
input bool   InpTradeWednesday   = true;  // Trade Wednesday
input bool   InpTradeThursday    = true;  // Trade Thursday
input bool   InpTradeFriday      = true;  // Trade Friday

input group "=== Visual Settings ==="
input color  InpRangeColor       = clrDodgerBlue; // Range Box Color
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
int               g_trendDirection; // 1=bullish, -1=bearish, 0=neutral

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_objPrefix      = "GRB_" + IntegerToString(InpMagicNumber) + "_";
   g_trendEMAHandle = INVALID_HANDLE;

   if(InpUseTrendFilter)
     {
      g_trendEMAHandle = iMA(_Symbol, InpTrendTF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_trendEMAHandle == INVALID_HANDLE)
        {
         Print("Failed to create EMA indicator!");
         return(INIT_FAILED);
        }
     }

   ResetDailyState();
   g_lastDay = -1;

   Print("GoldRangeBreakout v4.0 | Magic=", InpMagicNumber,
         " | GMT=", InpBrokerGMTOffset,
         " | SessionClose=", InpCloseHour, ":", InpCloseMinute, " NY",
         " | Trend=", InpUseTrendFilter,
         " | BE@", DoubleToString(InpBETriggerR,1), "R+", DoubleToString(InpBELockR,1), "R",
         " | Trail@", DoubleToString(InpTrailStartR,1), "R dist=", DoubleToString(InpTrailDistR,1), "R");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_trendEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendEMAHandle);

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
   datetime closeTime  = NYTimeToBroker(InpCloseHour, InpCloseMinute);

//--- SESSION CLOSE: Close all positions and orders at end of session
   if(now >= closeTime && g_state != STATE_DONE_FOR_DAY)
     {
      if(g_state == STATE_ORDERS_PLACED)
         DeleteAllPendingOrders();
      if(g_state == STATE_TRADE_ACTIVE)
         CloseAllPositions();
      if(g_state != STATE_DONE_FOR_DAY)
        {
         g_state = STATE_DONE_FOR_DAY;
         Print("SESSION CLOSE at ", TimeToString(now, TIME_MINUTES));
        }
      return;
     }

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
               if(InpUseTrendFilter)
                  g_trendDirection = GetTrendDirection();
               g_state = STATE_RANGE_COMPLETE;
               Print("Range: H=", DoubleToString(g_rangeHigh, _Digits),
                     " L=", DoubleToString(g_rangeLow, _Digits),
                     " Size=$", DoubleToString(g_rangeSize, 2),
                     " Trend=", g_trendDirection);
               if(InpShowRange)
                  DrawRangeBox();
              }
            else
               g_state = STATE_DONE_FOR_DAY;
           }
         break;

      case STATE_RANGE_COMPLETE:
         PlacePendingOrders();
         break;

      case STATE_ORDERS_PLACED:
         CheckOCO();
         if(g_state == STATE_ORDERS_PLACED && now >= deleteTime)
           {
            Print("Order cutoff. Deleting unfilled orders.");
            DeleteAllPendingOrders();
            g_state = STATE_DONE_FOR_DAY;
           }
         break;

      case STATE_TRADE_ACTIVE:
         ManageOpenTrade();
         if(!HasOpenPosition())
            g_state = STATE_DONE_FOR_DAY;
         break;

      case STATE_DONE_FOR_DAY:
         break;
     }
  }

//+------------------------------------------------------------------+
//| Trading day filter                                                |
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
      default: return false;
     }
  }

//+------------------------------------------------------------------+
//| Get trend direction: 1=bull, -1=bear, 0=neutral                   |
//+------------------------------------------------------------------+
int GetTrendDirection()
  {
   if(!InpUseTrendFilter || g_trendEMAHandle == INVALID_HANDLE)
      return 0;

   double emaValue[1];
   if(CopyBuffer(g_trendEMAHandle, 0, 0, 1, emaValue) < 1)
      return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distance = bid - emaValue[0];
   double minDistance = g_rangeSize * 0.5; // Need meaningful distance from EMA

   if(distance > minDistance)
      return 1;   // Bullish: price clearly above EMA
   if(distance < -minDistance)
      return -1;  // Bearish: price clearly below EMA

   return 0; // Too close to EMA - neutral
  }

//+------------------------------------------------------------------+
//| Update range with current tick/bar data                           |
//+------------------------------------------------------------------+
void UpdateRangeFromTick()
  {
   double barHigh = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double barLow  = iLow(_Symbol, PERIOD_CURRENT, 0);
   if(barHigh > g_rangeHigh) g_rangeHigh = barHigh;
   if(barLow < g_rangeLow)   g_rangeLow  = barLow;
  }

//+------------------------------------------------------------------+
//| Final scan all bars within range window                           |
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
         if(h > g_rangeHigh) g_rangeHigh = h;
         if(l < g_rangeLow)  g_rangeLow  = l;
        }
     }
   g_rangeHigh = NormalizeDouble(g_rangeHigh, _Digits);
   g_rangeLow  = NormalizeDouble(g_rangeLow, _Digits);
   g_rangeSize = g_rangeHigh - g_rangeLow;
  }

//+------------------------------------------------------------------+
//| Validate range size (in price units, not points)                  |
//+------------------------------------------------------------------+
bool ValidateRange()
  {
   if(g_rangeHigh <= 0 || g_rangeLow >= DBL_MAX || g_rangeHigh <= g_rangeLow)
     {
      Print("Range invalid.");
      return false;
     }
   if(g_rangeSize < InpMinRangePrice)
     {
      Print("Range too small: $", DoubleToString(g_rangeSize, 2),
            " < $", DoubleToString(InpMinRangePrice, 2));
      return false;
     }
   if(g_rangeSize > InpMaxRangePrice)
     {
      Print("Range too large: $", DoubleToString(g_rangeSize, 2),
            " > $", DoubleToString(InpMaxRangePrice, 2));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Place pending stop orders                                         |
//+------------------------------------------------------------------+
void PlacePendingOrders()
  {
// Spread check
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopLevel * _Point;

// Entry with buffer
   double buyEntry  = NormalizeDouble(g_rangeHigh + InpEntryBuffer, _Digits);
   double sellEntry = NormalizeDouble(g_rangeLow - InpEntryBuffer, _Digits);

// SL at opposite extreme
   double buySL  = NormalizeDouble(g_rangeLow, _Digits);
   double sellSL = NormalizeDouble(g_rangeHigh, _Digits);

// Risk calculation
   double buyRisk  = buyEntry - buySL;
   double sellRisk = sellSL - sellEntry;

// TP
   double buyTP  = NormalizeDouble(buyEntry + InpTPMultiplier * buyRisk, _Digits);
   double sellTP = NormalizeDouble(sellEntry - InpTPMultiplier * sellRisk, _Digits);

   bool placedAny = false;

// Determine which directions are allowed
   bool allowBuy  = true;
   bool allowSell = true;

   if(InpUseTrendFilter && InpOnlyTrendDir)
     {
      // Only trend direction when OnlyTrendDir=true
      if(g_trendDirection == -1)  allowBuy  = false;
      if(g_trendDirection == 1)   allowSell = false;
      // Neutral (0): allow both (OCO behavior)
     }
   else if(InpUseTrendFilter && !InpOnlyTrendDir)
     {
      // Filter only counter-trend, but allow neutral
      if(g_trendDirection == -1) allowBuy  = false;
      if(g_trendDirection == 1)  allowSell = false;
     }

// Place BUY STOP
   if(allowBuy && buyEntry > ask + minDist)
     {
      if(trade.BuyStop(InpLotSize, buyEntry, _Symbol, buySL, buyTP,
                       ORDER_TIME_GTC, 0, "GRB Buy"))
        {
         g_buyTicket = trade.ResultOrder();
         Print("BUY STOP #", g_buyTicket,
               " E=", DoubleToString(buyEntry, _Digits),
               " SL=", DoubleToString(buySL, _Digits),
               " TP=", DoubleToString(buyTP, _Digits));
         placedAny = true;
        }
      else
         Print("FAIL BuyStop err=", GetLastError());
     }
   else if(!allowBuy)
      Print("BUY blocked: trend=", g_trendDirection);

// Place SELL STOP
   if(allowSell && sellEntry < bid - minDist)
     {
      if(trade.SellStop(InpLotSize, sellEntry, _Symbol, sellSL, sellTP,
                        ORDER_TIME_GTC, 0, "GRB Sell"))
        {
         g_sellTicket = trade.ResultOrder();
         Print("SELL STOP #", g_sellTicket,
               " E=", DoubleToString(sellEntry, _Digits),
               " SL=", DoubleToString(sellSL, _Digits),
               " TP=", DoubleToString(sellTP, _Digits));
         placedAny = true;
        }
      else
         Print("FAIL SellStop err=", GetLastError());
     }
   else if(!allowSell)
      Print("SELL blocked: trend=", g_trendDirection);

   if(placedAny)
      g_state = STATE_ORDERS_PLACED;
   else
     {
      Print("No orders placed.");
      g_state = STATE_DONE_FOR_DAY;
     }
  }

//+------------------------------------------------------------------+
//| OCO Logic                                                         |
//+------------------------------------------------------------------+
void CheckOCO()
  {
   bool buyPending  = (g_buyTicket > 0) && OrderExists(g_buyTicket);
   bool sellPending = (g_sellTicket > 0) && OrderExists(g_sellTicket);

   if(g_buyTicket > 0 && !buyPending && HasOpenPosition())
     {
      if(sellPending) trade.OrderDelete(g_sellTicket);
      g_state = STATE_TRADE_ACTIVE;
      Print("BUY triggered -> OCO");
      return;
     }

   if(g_sellTicket > 0 && !sellPending && HasOpenPosition())
     {
      if(buyPending) trade.OrderDelete(g_buyTicket);
      g_state = STATE_TRADE_ACTIVE;
      Print("SELL triggered -> OCO");
      return;
     }

   if(!buyPending && !sellPending && !HasOpenPosition())
      g_state = STATE_DONE_FOR_DAY;
  }

//+------------------------------------------------------------------+
//| Manage open trade: BE, trailing, partial close                    |
//+------------------------------------------------------------------+
void ManageOpenTrade()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      double riskSize = MathAbs(openPrice - sl);
      if(riskSize < _Point) continue;

      if(posType == POSITION_TYPE_BUY)
         ManageBuy(ticket, openPrice, sl, tp, volume, riskSize);
      else if(posType == POSITION_TYPE_SELL)
         ManageSell(ticket, openPrice, sl, tp, volume, riskSize);
     }
  }

//+------------------------------------------------------------------+
//| Manage BUY position                                               |
//+------------------------------------------------------------------+
void ManageBuy(ulong ticket, double openPrice, double sl, double tp,
               double volume, double riskSize)
  {
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double profitR = (currentBid - openPrice) / riskSize;

//--- Partial close
   if(InpUsePartialClose && !g_partialClosed && profitR >= InpPartialTriggerR)
     {
      double closeVol = NormalizeVolume(volume * InpPartialPercent / 100.0);
      if(closeVol > 0 && closeVol < volume)
        {
         if(trade.PositionClosePartial(ticket, closeVol))
           {
            Print("PARTIAL BUY ", DoubleToString(InpPartialPercent, 0), "% at ",
                  DoubleToString(profitR, 1), "R");
            g_partialClosed = true;
           }
        }
     }

//--- Trailing stop (runs continuously after activation)
   if(InpUseTrailingStop && profitR >= InpTrailStartR)
     {
      double trailSL = NormalizeDouble(currentBid - InpTrailDistR * riskSize, _Digits);
      // Only move SL up, never down
      if(trailSL > sl)
        {
         if(trade.PositionModify(ticket, trailSL, tp))
           {
            Print("TRAIL BUY SL=", DoubleToString(trailSL, _Digits),
                  " lock=", DoubleToString((trailSL - openPrice) / riskSize, 2), "R");
            g_breakEvenApplied = true;
           }
        }
     }
//--- Break-even (only if trailing is off or hasn't triggered yet)
   else if(InpUseBreakEven && !g_breakEvenApplied && profitR >= InpBETriggerR)
     {
      double beSL = NormalizeDouble(openPrice + InpBELockR * riskSize, _Digits);
      if(beSL > sl)
        {
         if(trade.PositionModify(ticket, beSL, tp))
           {
            Print("BE BUY SL=", DoubleToString(beSL, _Digits),
                  " lock=+", DoubleToString(InpBELockR, 2), "R");
            g_breakEvenApplied = true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Manage SELL position                                              |
//+------------------------------------------------------------------+
void ManageSell(ulong ticket, double openPrice, double sl, double tp,
                double volume, double riskSize)
  {
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitR = (openPrice - currentAsk) / riskSize;

//--- Partial close
   if(InpUsePartialClose && !g_partialClosed && profitR >= InpPartialTriggerR)
     {
      double closeVol = NormalizeVolume(volume * InpPartialPercent / 100.0);
      if(closeVol > 0 && closeVol < volume)
        {
         if(trade.PositionClosePartial(ticket, closeVol))
           {
            Print("PARTIAL SELL ", DoubleToString(InpPartialPercent, 0), "% at ",
                  DoubleToString(profitR, 1), "R");
            g_partialClosed = true;
           }
        }
     }

//--- Trailing stop (runs continuously after activation)
   if(InpUseTrailingStop && profitR >= InpTrailStartR)
     {
      double trailSL = NormalizeDouble(currentAsk + InpTrailDistR * riskSize, _Digits);
      // Only move SL down (toward profit), never up
      if(trailSL < sl)
        {
         if(trade.PositionModify(ticket, trailSL, tp))
           {
            Print("TRAIL SELL SL=", DoubleToString(trailSL, _Digits),
                  " lock=", DoubleToString((openPrice - trailSL) / riskSize, 2), "R");
            g_breakEvenApplied = true;
           }
        }
     }
//--- Break-even (only if trailing is off or hasn't triggered yet)
   else if(InpUseBreakEven && !g_breakEvenApplied && profitR >= InpBETriggerR)
     {
      double beSL = NormalizeDouble(openPrice - InpBELockR * riskSize, _Digits);
      if(beSL < sl)
        {
         if(trade.PositionModify(ticket, beSL, tp))
           {
            Print("BE SELL SL=", DoubleToString(beSL, _Digits),
                  " lock=+", DoubleToString(InpBELockR, 2), "R");
            g_breakEvenApplied = true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Normalize volume                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepVol <= 0) stepVol = 0.01;
   volume = MathFloor(volume / stepVol) * stepVol;
   if(volume < minVol) return 0;
   return NormalizeDouble(volume, 2);
  }

//+------------------------------------------------------------------+
//| Check if pending order exists                                     |
//+------------------------------------------------------------------+
bool OrderExists(ulong ticket)
  {
   if(ticket == 0) return false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) == ticket) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Check if open position exists                                     |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Close all positions with our magic                                |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         trade.PositionClose(ticket);
         Print("SESSION CLOSE position #", ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Delete all pending orders                                         |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber &&
         OrderGetString(ORDER_SYMBOL) == _Symbol)
         trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Cleanup on new day                                                |
//+------------------------------------------------------------------+
void CleanupPendingOrders()
  {
   DeleteAllPendingOrders();
  }

//+------------------------------------------------------------------+
//| NY Time -> Broker Time                                            |
//+------------------------------------------------------------------+
datetime NYTimeToBroker(int nyHour, int nyMinute)
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   bool isDST = IsUSDST(dt.year, dt.mon, dt.day);
   int nyToUTC = isDST ? 4 : 5;
   int shift   = nyToUTC + InpBrokerGMTOffset;

   dt.hour = nyHour + shift;
   dt.min  = nyMinute;
   dt.sec  = 0;
   while(dt.hour >= 24) dt.hour -= 24;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| US DST detection                                                  |
//+------------------------------------------------------------------+
bool IsUSDST(int year, int month, int day)
  {
   if(month > 3 && month < 11)  return true;
   if(month < 3 || month > 11)  return false;
   if(month == 3)
     {
      int dow1 = DayOfWeekCalc(year, 3, 1);
      int firstSun = (dow1 == 0) ? 1 : (8 - dow1);
      return (day >= firstSun + 7);
     }
   if(month == 11)
     {
      int dow1 = DayOfWeekCalc(year, 11, 1);
      int firstSun = (dow1 == 0) ? 1 : (8 - dow1);
      return (day < firstSun);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Zeller day of week (0=Sun, 1=Mon, ... 6=Sat)                     |
//+------------------------------------------------------------------+
int DayOfWeekCalc(int year, int month, int day)
  {
   if(month < 3) { month += 12; year--; }
   int k = year % 100;
   int j = year / 100;
   int h = (day + (13*(month+1))/5 + k + k/4 + j/4 - 2*j) % 7;
   return ((h + 6) % 7);
  }

//+------------------------------------------------------------------+
//| Draw range box                                                    |
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
   ObjectSetInteger(0, objName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, objName, OBJPROP_FILL, InpFillRange);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, objName, OBJPROP_TOOLTIP,
                   "H=" + DoubleToString(g_rangeHigh, _Digits) +
                   " L=" + DoubleToString(g_rangeLow, _Digits) +
                   " $" + DoubleToString(g_rangeSize, 2) +
                   " T=" + IntegerToString(g_trendDirection));
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
