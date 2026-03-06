//+------------------------------------------------------------------+
//|                                             GoldRangeBreakout.mq5|
//|                          Gold 5M NY Open Range Breakout Strategy |
//|                                                                  |
//| Logic:                                                           |
//|  1. Mark High/Low range during configurable time window          |
//|  2. Place BuyStop at High, SellStop at Low (SL = opposite end)  |
//|  3. When one triggers, cancel the other                          |
//|  4. Optional Break Even at 1:1 R                                 |
//|  5. TP = N x R (configurable for optimization)                   |
//|  6. Draws colored rectangle for the range                        |
//+------------------------------------------------------------------+
#property copyright "2024"
#property version   "1.00"
#property description "Gold 5M NY Open Range Breakout EA"

#include <Trade\Trade.mqh>

//--- Inputs
input group "=== Timing (Server/Broker Time) ==="
input int    RangeStartHour = 12;         // Range Start Hour
input int    RangeStartMin  = 30;         // Range Start Minute
input int    RangeEndHour   = 12;         // Range End Hour
input int    RangeEndMin    = 45;         // Range End Minute

input group "=== Trade Settings ==="
input double RiskPercent    = 1.0;        // Risk % of Balance
input double TPmultiplier   = 3.0;        // TP Multiplier (R) — use for optimization
input bool   EnableBE       = true;       // Enable Break Even at 1:1 R
input ulong  MagicNumber    = 202401;     // Magic Number
input int    Slippage       = 30;         // Slippage (points)

input group "=== Visual ==="
input bool   ShowRange      = true;       // Draw Range Rectangle
input color  RangeColor     = clrSteelBlue; // Rectangle Color

//--- Globals
CTrade   trade;
double   gHigh      = 0;
double   gLow       = 0;
bool     gBuilt     = false;
bool     gPlaced    = false;
ulong    gBuyTkt    = 0;
ulong    gSellTkt   = 0;
datetime gLastDay   = 0;
datetime gRectT1    = 0;
string   gRectName  = "";

//+------------------------------------------------------------------+
//| Lot size from risk % and SL distance in price                   |
//+------------------------------------------------------------------+
double CalcLots(double slDist) {
    if (slDist <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt  = balance * RiskPercent / 100.0;
    double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    double lossPerLot = (slDist / tickSz) * tickVal;
    if (lossPerLot <= 0) return minLot;

    double lots = MathFloor((riskAmt / lossPerLot) / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| Draw / update the range rectangle                               |
//+------------------------------------------------------------------+
void DrawRangeRect() {
    if (!ShowRange) return;

    datetime t1 = gRectT1;
    datetime t2 = t1 + (RangeEndHour * 3600 + RangeEndMin * 60)
                      - (RangeStartHour * 3600 + RangeStartMin * 60)
                      + PeriodSeconds(PERIOD_M5);

    if (gRectName == "") {
        gRectName = "GRB_" + TimeToString(t1, TIME_DATE | TIME_MINUTES);
        ObjectCreate(0, gRectName, OBJ_RECTANGLE, 0, t1, gHigh, t2, gLow);
    } else {
        ObjectMove(0, gRectName, 0, t1, gHigh);
        ObjectMove(0, gRectName, 1, t2, gLow);
    }

    ObjectSetInteger(0, gRectName, OBJPROP_COLOR,      RangeColor);
    ObjectSetInteger(0, gRectName, OBJPROP_FILL,       true);
    ObjectSetInteger(0, gRectName, OBJPROP_BACK,       true);
    ObjectSetInteger(0, gRectName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, gRectName, OBJPROP_HIDDEN,     true);
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Check if pending order ticket is still open                     |
//+------------------------------------------------------------------+
bool PendingExists(ulong ticket) {
    if (ticket == 0) return false;
    for (int i = OrdersTotal() - 1; i >= 0; i--)
        if (OrderGetTicket(i) == ticket) return true;
    return false;
}

//+------------------------------------------------------------------+
//| Place BuyStop and SellStop at range extremes                    |
//+------------------------------------------------------------------+
void PlaceOrders() {
    int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double rangeDist = gHigh - gLow;

    if (rangeDist < _Point * 5) {
        Print("GRB: Range too small, skipping.");
        gPlaced = true; // mark so we don't retry every tick
        return;
    }

    double buyEntry  = NormalizeDouble(gHigh,                             digits);
    double buySL     = NormalizeDouble(gLow,                              digits);
    double buyTP     = NormalizeDouble(buyEntry + TPmultiplier * rangeDist, digits);

    double sellEntry = NormalizeDouble(gLow,                               digits);
    double sellSL    = NormalizeDouble(gHigh,                              digits);
    double sellTP    = NormalizeDouble(sellEntry - TPmultiplier * rangeDist, digits);

    double lots = CalcLots(rangeDist);

    if (trade.BuyStop(lots, buyEntry, _Symbol, buySL, buyTP,
                      ORDER_TIME_DAY, 0, "GRB_Buy"))
        gBuyTkt = trade.ResultOrder();
    else
        Print("GRB: BuyStop failed: ", trade.ResultRetcodeDescription());

    if (trade.SellStop(lots, sellEntry, _Symbol, sellSL, sellTP,
                       ORDER_TIME_DAY, 0, "GRB_Sell"))
        gSellTkt = trade.ResultOrder();
    else
        Print("GRB: SellStop failed: ", trade.ResultRetcodeDescription());

    gPlaced = true;
    PrintFormat("GRB: Orders placed | High=%.5f Low=%.5f Range=%.5f Lots=%.2f",
                gHigh, gLow, rangeDist, lots);
}

//+------------------------------------------------------------------+
//| If one order activated as position, cancel the other            |
//+------------------------------------------------------------------+
void MonitorActivation() {
    bool hasBuyPos  = false;
    bool hasSellPos = false;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (PositionGetTicket(i) == 0) continue;
        if (PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;
        if (PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
        ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if (pt == POSITION_TYPE_BUY)  hasBuyPos  = true;
        if (pt == POSITION_TYPE_SELL) hasSellPos = true;
    }

    if (hasBuyPos && PendingExists(gSellTkt)) {
        trade.OrderDelete(gSellTkt);
        gSellTkt = 0;
        Print("GRB: Buy activated — SellStop cancelled.");
    }
    if (hasSellPos && PendingExists(gBuyTkt)) {
        trade.OrderDelete(gBuyTkt);
        gBuyTkt = 0;
        Print("GRB: Sell activated — BuyStop cancelled.");
    }
}

//+------------------------------------------------------------------+
//| Move SL to Break Even when price hits 1:1 R                     |
//+------------------------------------------------------------------+
void CheckBreakEven() {
    if (!EnableBE) return;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong tkt = PositionGetTicket(i);
        if (PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)           continue;

        double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl     = PositionGetDouble(POSITION_SL);
        double tp     = PositionGetDouble(POSITION_TP);
        double rDist  = MathAbs(openPx - sl);
        ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        if (pt == POSITION_TYPE_BUY) {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            // Moved 1R in profit and SL not yet at BE
            if (bid >= openPx + rDist && sl < openPx - _Point)
                trade.PositionModify(tkt, openPx + _Point, tp);
        } else {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if (ask <= openPx - rDist && sl > openPx + _Point)
                trade.PositionModify(tkt, openPx - _Point, tp);
        }
    }
}

//+------------------------------------------------------------------+
//| Reset all daily state                                           |
//+------------------------------------------------------------------+
void DailyReset() {
    gHigh     = 0;
    gLow      = 0;
    gBuilt    = false;
    gPlaced   = false;
    gBuyTkt   = 0;
    gSellTkt  = 0;
    gRectName = "";
    gRectT1   = 0;
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    PrintFormat("GRB Init | Range %02d:%02d-%02d:%02d | TP=%.1fR | BE=%s",
                RangeStartHour, RangeStartMin, RangeEndHour, RangeEndMin,
                TPmultiplier, EnableBE ? "ON" : "OFF");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Leave rectangle on chart for visual reference
}

//+------------------------------------------------------------------+
//| Main tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);

    // --- Daily reset at midnight ---
    datetime today = now - (datetime)(dt.hour * 3600 + dt.min * 60 + dt.sec);
    if (today != gLastDay) {
        gLastDay = today;
        DailyReset();
    }

    int nowMin   = dt.hour * 60 + dt.min;
    int startMin = RangeStartHour * 60 + RangeStartMin;
    int endMin   = RangeEndHour   * 60 + RangeEndMin;

    // --- Build range during window ---
    if (nowMin >= startMin && nowMin < endMin && !gPlaced) {
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if (gRectT1 == 0)
            gRectT1 = today + RangeStartHour * 3600 + RangeStartMin * 60;

        bool changed = false;
        if (gHigh == 0 || bid > gHigh) { gHigh = bid; changed = true; }
        if (gLow  == 0 || ask < gLow)  { gLow  = ask; changed = true; }

        if (changed) DrawRangeRect();
        gBuilt = true;
    }

    // --- Place pending orders once, right after window closes ---
    if (nowMin >= endMin && gBuilt && !gPlaced)
        PlaceOrders();

    // --- Monitor active orders ---
    if (gPlaced) {
        MonitorActivation();
        CheckBreakEven();
    }
}
//+------------------------------------------------------------------+
