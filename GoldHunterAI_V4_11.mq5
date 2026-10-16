//+------------------------------------------------------------------+
//| GOLD HUNTER AI V4 - safety upgrade                               |
//| V4.11 daily-state persistence hardening; test before use.       |
//+------------------------------------------------------------------+
#property strict
#property version   "4.11"
#property description "Structure-confirmed, multi-timeframe trend EA with safety controls"

#include <Trade\Trade.mqh>
CTrade trade;

input string InpSymbol = "";                 // Blank = chart symbol
input bool EnableTrading = false;            // Keep OFF until verified
input bool DemoOnly = true;                  // Block entries on real accounts
input double RiskPercent = 0.50;             // Equity risk per trade
input double DailyLossLimitPercent = 2.0;
input int MaxEntriesPerDay = 3;               // Maximum accepted entries per server day
input double RewardRiskRatio = 1.5;
input double ATRStopMultiplier = 2.0;
input double ATRTrailMultiplier = 1.5;
input int ATRPeriod = 14;
input int FastEMA = 20;
input int SlowEMA = 50;
input int RSIPeriod = 14;
input int StructureLookback = 12;
input int MaxSpreadPoints = 150;
input int SlippagePoints = 20;
input ulong MagicNumber = 20261012;

string sym;
int fast15 = INVALID_HANDLE, slow15 = INVALID_HANDLE;
int fastH1 = INVALID_HANDLE, slowH1 = INVALID_HANDLE;
int atrH = INVALID_HANDLE, rsiH = INVALID_HANDLE;
datetime lastBar = 0;
double dayStartEquity = 0.0;
int dayKey = -1;
bool dayLocked = false;
int entriesToday = 0;
bool dailyStateReady = false;
string gvPrefix;

int DateKey()
{
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   return d.year * 10000 + d.mon * 100 + d.day;
}

string DayStateKeyForDate(const int date, const string suffix)
{
   return gvPrefix + IntegerToString(date) + "_" + suffix;
}

bool SaveGlobalValue(const string key, const double value)
{
   datetime savedAt = GlobalVariableSet(key, value);
   if(savedAt == 0)
   {
      Print("SAFETY ERROR: Could not persist daily state key: ", key,
            ". New entries will be blocked.");
      return false;
   }
   GlobalVariablesFlush();
   return true;
}

bool LoadOrCreateDailyState()
{
   // Do not mark the state ready until every value for this date is valid.
   dailyStateReady = false;
   int targetDay = DateKey();
   string equityKey = DayStateKeyForDate(targetDay, "equity");
   string lockKey   = DayStateKeyForDate(targetDay, "locked");
   string countKey  = DayStateKeyForDate(targetDay, "entries");

   double loadedEquity = 0.0;
   double loadedLock = 0.0;
   double loadedCount = 0.0;

   if(GlobalVariableCheck(equityKey))
   {
      loadedEquity = GlobalVariableGet(equityKey);
      if(!MathIsValidNumber(loadedEquity) || loadedEquity <= 0.0)
      {
         Print("SAFETY ERROR: Invalid saved daily starting equity. New entries blocked.");
         return false;
      }
   }
   else
   {
      loadedEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(!MathIsValidNumber(loadedEquity) || loadedEquity <= 0.0) return false;
      if(!SaveGlobalValue(equityKey, loadedEquity)) return false;
   }

   if(GlobalVariableCheck(lockKey))
      loadedLock = GlobalVariableGet(lockKey);
   else if(!SaveGlobalValue(lockKey, 0.0))
      return false;

   if(!MathIsValidNumber(loadedLock) || (loadedLock != 0.0 && loadedLock != 1.0))
   {
      Print("SAFETY ERROR: Invalid saved daily lock state. New entries blocked.");
      return false;
   }

   if(GlobalVariableCheck(countKey))
      loadedCount = GlobalVariableGet(countKey);
   else if(!SaveGlobalValue(countKey, 0.0))
      return false;

   if(!MathIsValidNumber(loadedCount) || loadedCount < 0.0 ||
      loadedCount > 1000000.0 || MathFloor(loadedCount) != loadedCount)
   {
      Print("SAFETY ERROR: Invalid saved daily entry count. New entries blocked.");
      return false;
   }

   // Only publish the loaded state after all required values are available.
   dayStartEquity = loadedEquity;
   dayLocked = (loadedLock > 0.5);
   entriesToday = (int)loadedCount;
   dayKey = targetDay;
   dailyStateReady = true;
   return true;
}

bool Buf(const int h, const int shift, double &v)
{
   double a[1];
   if(h == INVALID_HANDLE || BarsCalculated(h) <= shift) return false;
   if(CopyBuffer(h, 0, shift, 1, a) != 1) return false;
   v = a[0];
   return MathIsValidNumber(v);
}

bool NewBar()
{
   datetime t = iTime(sym, PERIOD_M15, 0);
   if(t <= 0 || t == lastBar) return false;
   lastBar = t;
   return true;
}

bool DemoAccount()
{
   return (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)
          == ACCOUNT_TRADE_MODE_DEMO;
}

bool DailyGuard()
{
   int today = DateKey();
   if(!dailyStateReady || today != dayKey)
   {
      if(!LoadOrCreateDailyState()) return true;
   }

   if(dayStartEquity <= 0.0) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!MathIsValidNumber(equity) || equity <= 0.0) return true;
   double lossPercent = (dayStartEquity - equity) / dayStartEquity * 100.0;
   if(lossPercent >= DailyLossLimitPercent && !dayLocked)
   {
      // Lock this running session first, even if persistence subsequently fails.
      dayLocked = true;
      SaveGlobalValue(DayStateKeyForDate(dayKey, "locked"), 1.0);
   }
   return dayLocked;
}

bool SpreadOK()
{
   MqlTick t;
   double p = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(p <= 0.0 || !SymbolInfoTick(sym, t)) return false;
   return (t.ask - t.bid) / p <= MaxSpreadPoints;
}

bool AnyPositionOnSymbol()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == sym) return true;
   }
   return false;
}

bool OurPosition(ulong &ticket, ENUM_POSITION_TYPE &type, double &sl, double &tp)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      ticket = t;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      return true;
   }
   return false;
}

// +1 BUY, -1 SELL, 0 NO TRADE. Original signal rules are retained.
int Signal()
{
   double fh, sh, fm, sm, rsi, atr;
   if(!Buf(fastH1, 1, fh) || !Buf(slowH1, 1, sh) ||
      !Buf(fast15, 1, fm) || !Buf(slow15, 1, sm) ||
      !Buf(rsiH, 1, rsi) || !Buf(atrH, 1, atr) || atr <= 0.0)
      return 0;

   double c1 = iClose(sym, PERIOD_M15, 1);
   double c2 = iClose(sym, PERIOD_M15, 2);
   double o1 = iOpen(sym, PERIOD_M15, 1);
   if(c1 <= 0.0 || c2 <= 0.0 || o1 <= 0.0) return 0;

   int hs = iHighest(sym, PERIOD_M15, MODE_HIGH, StructureLookback, 2);
   int ls = iLowest(sym, PERIOD_M15, MODE_LOW, StructureLookback, 2);
   if(hs < 0 || ls < 0) return 0;
   double hi = iHigh(sym, PERIOD_M15, hs);
   double lo = iLow(sym, PERIOD_M15, ls);

   bool buy = (fh > sh && fm > sm && c2 <= fm && c1 > fm &&
               c1 > o1 && rsi >= 50.0 && rsi <= 70.0 && hi - c1 > atr * 0.25);
   bool sell = (fh < sh && fm < sm && c2 >= fm && c1 < fm &&
                c1 < o1 && rsi <= 50.0 && rsi >= 30.0 && c1 - lo > atr * 0.25);
   if(buy) return 1;
   if(sell) return -1;
   return 0;
}

int VolumeDigits(const double step)
{
   for(int d = 0; d <= 8; d++)
      if(MathAbs(step - NormalizeDouble(step, d)) < 1e-10) return d;
   return 8;
}

double VolumeForRisk(const ENUM_ORDER_TYPE ot, const double entry, const double stop)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk = eq * RiskPercent / 100.0;
   double pnl = 0.0;
   if(eq <= 0.0 || risk <= 0.0 || !OrderCalcProfit(ot, sym, 1.0, entry, stop, pnl)) return 0.0;

   double loss = MathAbs(pnl);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(loss <= 0.0 || step <= 0.0 || minv <= 0.0 || maxv <= 0.0) return 0.0;

   double rawVolume = MathMin(risk / loss, maxv);
   double volume = MathFloor(rawVolume / step + 1e-9) * step;
   volume = NormalizeDouble(volume, VolumeDigits(step));
   // Never force minimum lot if it would exceed the chosen risk budget.
   if(volume < minv) return 0.0;
   return volume;
}

void OpenTrade(const int s)
{
   MqlTick t;
   double atr;
   if(!SymbolInfoTick(sym, t) || !Buf(atrH, 1, atr) || atr <= 0.0) return;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(point <= 0.0) return;

   double entry = (s > 0) ? t.ask : t.bid;
   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double dist = MathMax(atr * ATRStopMultiplier, (stopsLevel + 2) * point);
   double sl = NormalizeDouble((s > 0) ? entry - dist : entry + dist, digits);
   double tp = NormalizeDouble((s > 0) ? entry + dist * RewardRiskRatio : entry - dist * RewardRiskRatio, digits);
   ENUM_ORDER_TYPE ot = (s > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double vol = VolumeForRisk(ot, entry, sl);
   if(vol <= 0.0)
   {
      Print("Entry rejected: calculated volume is invalid or below broker minimum for the risk budget.");
      return;
   }

   bool ok = (s > 0)
             ? trade.Buy(vol, sym, 0.0, sl, tp, "GHV4 confirmed BUY")
             : trade.Sell(vol, sym, 0.0, sl, tp, "GHV4 confirmed SELL");
   uint rc = trade.ResultRetcode();
   bool accepted = (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
   if(!ok || !accepted)
   {
      Print("Order failed: ", rc, " ", trade.ResultRetcodeDescription());
      return;
   }

   entriesToday++;
   if(!SaveGlobalValue(DayStateKeyForDate(dayKey, "entries"), (double)entriesToday))
   {
      // The order may already be accepted. Never retry it; block any further entries.
      dayLocked = true;
      SaveGlobalValue(DayStateKeyForDate(dayKey, "locked"), 1.0);
      Print("SAFETY ERROR: Order was accepted but daily entry count could not be saved. ",
            "Further entries are locked for this session.");
      return;
   }
   Print("Entry accepted. Entries today: ", entriesToday, "/", MaxEntriesPerDay);
}

void ManagePosition()
{
   ulong ticket;
   ENUM_POSITION_TYPE type;
   double sl, tp;
   if(!OurPosition(ticket, type, sl, tp)) return;

   int sig = Signal();
   if((type == POSITION_TYPE_BUY && sig < 0) || (type == POSITION_TYPE_SELL && sig > 0))
   {
      if(!trade.PositionClose(ticket)) Print("Close failed: ", trade.ResultRetcodeDescription());
      return;
   }

   double atr;
   MqlTick t;
   if(!Buf(atrH, 1, atr) || !SymbolInfoTick(sym, t)) return;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(point <= 0.0) return;

   long stopsLevel = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;
   if(type == POSITION_TYPE_BUY)
   {
      double n = NormalizeDouble(t.bid - atr * ATRTrailMultiplier, digits);
      if(n > sl + point && n < t.bid && t.bid - n >= minDistance)
         if(!trade.PositionModify(ticket, n, tp)) Print("BUY trail update failed: ", trade.ResultRetcodeDescription());
   }
   else
   {
      double n = NormalizeDouble(t.ask + atr * ATRTrailMultiplier, digits);
      if((sl == 0.0 || n < sl - point) && n > t.ask && n - t.ask >= minDistance)
         if(!trade.PositionModify(ticket, n, tp)) Print("SELL trail update failed: ", trade.ResultRetcodeDescription());
   }
}

int OnInit()
{
   sym = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(sym, true)) return INIT_FAILED;
   if(RiskPercent <= 0.0 || RiskPercent > 5.0 || DailyLossLimitPercent <= 0.0 ||
      DailyLossLimitPercent > 100.0 || MaxEntriesPerDay < 1 || RewardRiskRatio <= 0.0 ||
      ATRStopMultiplier <= 0.0 || ATRTrailMultiplier <= 0.0 || FastEMA < 2 ||
      SlowEMA <= FastEMA || ATRPeriod < 2 || RSIPeriod < 2 || StructureLookback < 4 ||
      MaxSpreadPoints < 0 || SlippagePoints < 0)
      return INIT_PARAMETERS_INCORRECT;

   fast15 = iMA(sym, PERIOD_M15, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slow15 = iMA(sym, PERIOD_M15, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   fastH1 = iMA(sym, PERIOD_H1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowH1 = iMA(sym, PERIOD_H1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   atrH = iATR(sym, PERIOD_M15, ATRPeriod);
   rsiH = iRSI(sym, PERIOD_M15, RSIPeriod, PRICE_CLOSE);
   if(fast15 == INVALID_HANDLE || slow15 == INVALID_HANDLE || fastH1 == INVALID_HANDLE ||
      slowH1 == INVALID_HANDLE || atrH == INVALID_HANDLE || rsiH == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints((ulong)SlippagePoints);
   trade.SetTypeFillingBySymbol(sym);
   gvPrefix = "GHV4_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString((long)MagicNumber) + "_";

   if(!LoadOrCreateDailyState())
   {
      Print("Cannot initialize persistent daily guard state; initialization aborted.");
      return INIT_FAILED;
   }
   Print("GH V4.11 initialized. Trading ", EnableTrading ? "enabled" : "DISABLED",
         ". DemoOnly=", DemoOnly, ". Test in Strategy Tester and on demo first.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fast15 != INVALID_HANDLE) IndicatorRelease(fast15);
   if(slow15 != INVALID_HANDLE) IndicatorRelease(slow15);
   if(fastH1 != INVALID_HANDLE) IndicatorRelease(fastH1);
   if(slowH1 != INVALID_HANDLE) IndicatorRelease(slowH1);
   if(atrH != INVALID_HANDLE) IndicatorRelease(atrH);
   if(rsiH != INVALID_HANDLE) IndicatorRelease(rsiH);
}

void OnTick()
{
   // Manage the EA's existing position before applying the entry lock.
   // Preserve the original M15-new-bar management cadence.
   bool newBar = NewBar();
   if(newBar) ManagePosition();

   if(DailyGuard()) return;
   if(!EnableTrading || !TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return;
   if(DemoOnly && !DemoAccount()) return;
   if(entriesToday >= MaxEntriesPerDay) return;
   if(!newBar || !SpreadOK() || AnyPositionOnSymbol()) return;

   int s = Signal();
   if(s != 0 && !DailyGuard() && dailyStateReady && entriesToday < MaxEntriesPerDay)
      OpenTrade(s);
}
