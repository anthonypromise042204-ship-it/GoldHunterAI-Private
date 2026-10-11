//+------------------------------------------------------------------+
//| GOLD HUNTER AI V3.4 - Controlled safety revision                 |
//| Strategy: H1 EMA trend + M15 EMA pullback, ATR stop              |
//| IMPORTANT: Uncompiled source draft. Test in Strategy Tester/demo. |
//+------------------------------------------------------------------+
#property strict
#property version "3.40"
#property description "Demo-first EMA pullback EA; controlled safety revision, uncompiled source"

#include <Trade/Trade.mqh>

CTrade trade;

input string InpSymbol = "";                 // Blank = chart symbol (attach to XAUUSDM)
input double RiskPercent = 0.5;              // Planned risk per trade (% equity)
input double DailyLossLimitPercent = 2.0;    // Daily equity drawdown lock (%)
input double RewardRiskRatio = 1.5;
input double ATRMultiplier = 2.0;
input int ATRPeriod = 14;
input int FastEMA = 20;
input int SlowEMA = 50;
input int MaxSpreadPoints = 150;             // Must be checked against broker conditions
input int SlippagePoints = 20;
input ulong MagicNumber = 20261010;
input bool DemoOnly = true;                  // Blocks non-demo accounts
input bool EnableTrading = false;            // SAFETY: default OFF until tested

string TradeSymbol;
int hFastM15 = INVALID_HANDLE, hSlowM15 = INVALID_HANDLE;
int hFastH1 = INVALID_HANDLE, hSlowH1 = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
datetime LastBarTime = 0;
string DailyBaselineKey = "", DailyLockKey = "", DailyTrustedKey = "", LastSeenDateKey = "";
bool DailyBaselineTrusted = false;

int OnInit()
{
   TradeSymbol = (InpSymbol == "") ? _Symbol : InpSymbol;

   if(!SymbolSelect(TradeSymbol, true))
   {
      Print("Cannot select symbol: ", TradeSymbol);
      return INIT_FAILED;
   }

   if(RiskPercent <= 0.0 || RiskPercent > 5.0 ||
      DailyLossLimitPercent <= 0.0 || DailyLossLimitPercent > 20.0 ||
      RewardRiskRatio <= 0.0 || ATRMultiplier <= 0.0 ||
      ATRPeriod < 1 || FastEMA < 1 || SlowEMA < 2 ||
      MaxSpreadPoints < 0 || SlippagePoints < 0)
      return INIT_PARAMETERS_INCORRECT;

   hFastM15 = iMA(TradeSymbol, PERIOD_M15, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowM15 = iMA(TradeSymbol, PERIOD_M15, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hFastH1  = iMA(TradeSymbol, PERIOD_H1, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowH1  = iMA(TradeSymbol, PERIOD_H1, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR     = iATR(TradeSymbol, PERIOD_M15, ATRPeriod);

   if(hFastM15 == INVALID_HANDLE || hSlowM15 == INVALID_HANDLE ||
      hFastH1 == INVALID_HANDLE || hSlowH1 == INVALID_HANDLE ||
      hATR == INVALID_HANDLE)
   {
      Print("Indicator initialization failed.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(TradeSymbol);

   RefreshDailyKeys();
   LogEvent("EA_STARTED", "V3.4 safety revision; trading disabled by default; compile and test before use");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFastM15 != INVALID_HANDLE) IndicatorRelease(hFastM15);
   if(hSlowM15 != INVALID_HANDLE) IndicatorRelease(hSlowM15);
   if(hFastH1 != INVALID_HANDLE) IndicatorRelease(hFastH1);
   if(hSlowH1 != INVALID_HANDLE) IndicatorRelease(hSlowH1);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
}

string BrokerDateText()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
}

void RefreshDailyKeys()
{
   string dateText = BrokerDateText();
   string prefix = StringFormat("GH34_%I64d_%I64u_%s",
                                AccountInfoInteger(ACCOUNT_LOGIN),
                                MagicNumber, dateText);
   DailyBaselineKey = prefix + "_BASE";
   DailyLockKey = prefix + "_LOCK";
   DailyTrustedKey = prefix + "_TRUSTED";
   LastSeenDateKey = StringFormat("GH34_%I64d_%I64u_LASTDATE",
                                  AccountInfoInteger(ACCOUNT_LOGIN), MagicNumber);

   if(!GlobalVariableCheck(DailyBaselineKey))
   {
      // A newly attached EA cannot reconstruct midnight equity reliably from current equity.
      // Trust a new baseline only if this EA previously observed a different broker-server date.
      // The snapshot is first-observed equity for the new server day, not guaranteed midnight equity.
      bool sawPreviousDate = false;
      if(GlobalVariableCheck(LastSeenDateKey))
      {
         string previousDate = DoubleToString(GlobalVariableGet(LastSeenDateKey), 0);
         sawPreviousDate = (previousDate != dateText);
      }
      GlobalVariableSet(DailyBaselineKey, AccountInfoDouble(ACCOUNT_EQUITY));
      DailyBaselineTrusted = sawPreviousDate;
      GlobalVariableSet(DailyTrustedKey, DailyBaselineTrusted ? 1.0 : 0.0);
      if(!DailyBaselineTrusted)
         Print("Daily baseline initialized without observed date continuity; new trades blocked until a later observed server-day rollover.");
   }
   else
   {
      DailyBaselineTrusted = GlobalVariableCheck(DailyTrustedKey) &&
                             GlobalVariableGet(DailyTrustedKey) >= 1.0;
   }
   GlobalVariableSet(LastSeenDateKey, StringToDouble(dateText));
}

// Baseline is a broker-server-day equity snapshot. If the EA is first attached mid-day
// and cannot verify a rollover, the baseline is marked untrusted and new entries are blocked.
double DailyStartEquity()
{
   RefreshDailyKeys();
   if(DailyBaselineKey == "" || !GlobalVariableCheck(DailyBaselineKey))
      return 0.0;
   return GlobalVariableGet(DailyBaselineKey);
}

// Attempts to close only this EA's positions on the configured symbol.
// A close can fail or execute at a worse price; this is not a hard loss guarantee.
void CloseEAOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue; // PositionGetTicket selects this position when successful.

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(symbol != TradeSymbol || magic != MagicNumber) continue;

      ResetLastError();
      bool closed = trade.PositionClose(ticket);
      uint rc = trade.ResultRetcode();
      if(closed && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
      {
         LogEvent("DAILY_LOCK_CLOSE", StringFormat("Close requested for ticket %I64u", ticket));
      }
      else
      {
         Print("Daily-loss close attempt failed for ticket ", ticket, ": ",
               rc, " ", trade.ResultRetcodeDescription(), "; error=", GetLastError());
         LogEvent("DAILY_LOCK_CLOSE_FAILED", StringFormat("Ticket=%I64u; retcode=%u", ticket, rc));
      }
   }
}

// Locks new entries after the equity threshold and repeatedly attempts to close
// positions belonging to this EA on TradeSymbol while the daily lock remains active.
bool DailyLossLocked()
{
   double startEquity = DailyStartEquity();
   if(startEquity <= 0.0)
   {
      Print("Daily baseline unavailable; blocking new entries.");
      return true;
   }

   if(GlobalVariableCheck(DailyLockKey) && GlobalVariableGet(DailyLockKey) >= 1.0)
   {
      CloseEAOpenPositions();
      return true;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (startEquity - equity) / startEquity * 100.0;

   if(lossPct >= DailyLossLimitPercent)
   {
      GlobalVariableSet(DailyLockKey, 1.0);
      LogEvent("DAILY_LOCK", "Daily equity drawdown threshold reached; attempting to close this EA's positions. Loss limit is not guaranteed.");
      CloseEAOpenPositions();
      return true;
   }

   // Keep managing the dashboard/lock, but do not trade on an untrusted first-day baseline.
   if(!DailyBaselineTrusted) return true;
   return false;
}

bool EnvironmentAllowed()
{
   if(!EnableTrading) return false;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;

   if(DemoOnly)
   {
      ENUM_ACCOUNT_TRADE_MODE mode =
         (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
      if(mode != ACCOUNT_TRADE_MODE_DEMO)
      {
         Print("DemoOnly is enabled: non-demo account blocked.");
         return false;
      }
   }
   return true;
}

bool ReadBufferValue(int handle, int shift, double &value)
{
   double buffer[1];
   if(handle == INVALID_HANDLE || BarsCalculated(handle) <= shift)
      return false;
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   value = buffer[0];
   return MathIsValidNumber(value) && value > 0.0;
}

bool NewM15Bar()
{
   datetime t = iTime(TradeSymbol, PERIOD_M15, 0);
   if(t <= 0) return false;
   if(t != LastBarTime)
   {
      LastBarTime = t;
      return true;
   }
   return false;
}

bool SpreadAcceptable()
{
   MqlTick tick;
   if(!SymbolInfoTick(TradeSymbol, tick)) return false;
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   if(point <= 0.0) return false;
   double spreadPoints = (tick.ask - tick.bid) / point;
   return spreadPoints <= MaxSpreadPoints;
}

// Conservative behavior preserved from V3.3: any position on this symbol, including
// manual/other-EA positions, blocks a new entry from this EA.
bool AnyPositionOnSymbol()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == TradeSymbol)
         return true;
   }
   return false;
}

int GetSignal()
{
   double fastH1, slowH1, fastM15, slowM15;
   if(!ReadBufferValue(hFastH1, 1, fastH1) ||
      !ReadBufferValue(hSlowH1, 1, slowH1) ||
      !ReadBufferValue(hFastM15, 1, fastM15) ||
      !ReadBufferValue(hSlowM15, 1, slowM15))
      return 0;

   double c1 = iClose(TradeSymbol, PERIOD_M15, 1);
   double c2 = iClose(TradeSymbol, PERIOD_M15, 2);
   double o1 = iOpen(TradeSymbol, PERIOD_M15, 1);
   if(c1 <= 0 || c2 <= 0 || o1 <= 0) return 0;

   bool buyPullback = (c2 <= fastM15 && c1 > fastM15 &&
                       c1 > o1 && fastM15 > slowM15);
   bool sellPullback = (c2 >= fastM15 && c1 < fastM15 &&
                        c1 < o1 && fastM15 < slowM15);

   if(fastH1 > slowH1 && buyPullback) return 1;
   if(fastH1 < slowH1 && sellPullback) return -1;
   return 0;
}

double CalculateVolume(double entryPrice, double stopPrice, ENUM_ORDER_TYPE orderType)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * RiskPercent / 100.0;
   double minVol = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);

   if(equity <= 0.0 || riskMoney <= 0.0 || minVol <= 0.0 ||
      maxVol <= 0.0 || volStep <= 0.0 || entryPrice <= 0.0 || stopPrice <= 0.0)
   {
      Print("Risk sizing unavailable; trade rejected.");
      return 0.0;
   }

   // Use broker/account-currency profit calculation for a 1-lot stop loss.
   // This is generally safer than assuming tick-value conversion is constant.
   double oneLotResult = 0.0;
   if(!OrderCalcProfit(orderType, TradeSymbol, 1.0, entryPrice, stopPrice, oneLotResult))
   {
      Print("OrderCalcProfit failed; trade rejected. Error: ", GetLastError());
      return 0.0;
   }
   double lossPerLot = MathAbs(oneLotResult);
   if(lossPerLot <= 0.0 || !MathIsValidNumber(lossPerLot))
   {
      Print("Could not calculate stop-loss risk; trade rejected.");
      return 0.0;
   }

   double rawVol = riskMoney / lossPerLot;
   double vol = MathFloor(rawVol / volStep + 1e-9) * volStep;
   vol = MathMin(vol, maxVol);

   int volDigits = 0;
   for(int d = 0; d <= 8; ++d)
   {
      if(MathAbs(volStep * MathPow(10.0, d) -
                 MathRound(volStep * MathPow(10.0, d))) < 1e-8)
      {
         volDigits = d;
         break;
      }
   }
   vol = NormalizeDouble(vol, volDigits);

   // Never round up to broker minimum: that could exceed the requested risk.
   if(vol < minVol)
   {
      Print("Trade rejected: minimum volume exceeds risk budget.");
      return 0.0;
   }

   // Verify estimated loss at the chosen volume does not exceed budget due to rounding.
   double estimatedResult = 0.0;
   if(!OrderCalcProfit(orderType, TradeSymbol, vol, entryPrice, stopPrice, estimatedResult) ||
      MathAbs(estimatedResult) > riskMoney * 1.001)
   {
      Print("Trade rejected: estimated stop loss exceeds risk budget.");
      return 0.0;
   }
   return vol;
}

double RoundPriceToTick(double price, bool roundUp)
{
   double tickSize = SymbolInfoDouble(TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   if(tickSize <= 0.0) return NormalizeDouble(price, digits);

   double units = price / tickSize;
   double rounded = roundUp ? MathCeil(units - 1e-10) :
                              MathFloor(units + 1e-10);
   return NormalizeDouble(rounded * tickSize, digits);
}

bool OpenTrade(int direction)
{
   MqlTick tick;
   if(!SymbolInfoTick(TradeSymbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return false;

   double atr;
   if(!ReadBufferValue(hATR, 1, atr)) return false;

   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(point <= 0.0 || atr <= 0.0) return false;

   // Use a small safety buffer beyond the broker's published stop/freeze distance.
   double minStop = (MathMax(stopsLevel, freezeLevel) + 2) * point;
   double stopDistance = MathMax(atr * ATRMultiplier, minStop);

   double entry, sl, tp, volume;
   ENUM_ORDER_TYPE orderType;
   if(direction > 0)
   {
      orderType = ORDER_TYPE_BUY;
      entry = tick.ask;
      sl = RoundPriceToTick(entry - stopDistance, false);
      tp = RoundPriceToTick(entry + stopDistance * RewardRiskRatio, true);
   }
   else
   {
      orderType = ORDER_TYPE_SELL;
      entry = tick.bid;
      sl = RoundPriceToTick(entry + stopDistance, true);
      tp = RoundPriceToTick(entry - stopDistance * RewardRiskRatio, false);
   }

   // Validate both protective levels against the executable side of the quote.
   double minDistance = (stopsLevel + 2) * point;
   if(sl <= 0.0 || tp <= 0.0 ||
      (direction > 0 && (sl >= tick.bid || tp <= tick.ask ||
                         (tick.bid - sl) < minDistance || (tp - tick.ask) < minDistance)) ||
      (direction < 0 && (sl <= tick.ask || tp >= tick.bid ||
                         (sl - tick.ask) < minDistance || (tick.bid - tp) < minDistance)))
   {
      Print("Invalid SL/TP distances for current quote; order rejected.");
      return false;
   }

   volume = CalculateVolume(entry, sl, orderType);
   if(volume <= 0.0) return false;

   // Check margin estimate before submitting the order.
   double marginRequired = 0.0;
   if(!OrderCalcMargin(orderType, TradeSymbol, volume, entry, marginRequired))
   {
      Print("Margin calculation failed; order rejected. Error: ", GetLastError());
      return false;
   }
   if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("Trade rejected: insufficient free margin for estimated margin requirement.");
      return false;
   }

   bool sent = false;
   if(direction > 0)
      sent = trade.Buy(volume, TradeSymbol, 0.0, sl, tp, "GOLD HUNTER V3.4 BUY");
   else
      sent = trade.Sell(volume, TradeSymbol, 0.0, sl, tp, "GOLD HUNTER V3.4 SELL");

   uint rc = trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE ||
               rc == TRADE_RETCODE_PLACED ||
               rc == TRADE_RETCODE_DONE_PARTIAL))
   {
      LogEvent("ORDER_ACCEPTED", direction > 0 ? "BUY" : "SELL");
      return true;
   }

   Print("Order failed: ", rc, " ", trade.ResultRetcodeDescription());
   LogEvent("ORDER_REJECTED", trade.ResultRetcodeDescription());
   return false;
}

void LogEvent(string eventName, string details)
{
   int file = FileOpen("GoldHunterAI_V3_4.csv",
                       FILE_READ | FILE_WRITE | FILE_CSV |
                       FILE_COMMON | FILE_SHARE_WRITE, ',');
   if(file == INVALID_HANDLE)
   {
      Print("Could not open CSV journal. Error: ", GetLastError());
      return;
   }
   FileSeek(file, 0, SEEK_END);
   FileWrite(file, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             TradeSymbol, eventName, details);
   FileClose(file);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;

   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber)
      return;

   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);

   string details = StringFormat("Volume=%.3f;Price=%.3f;Profit=%.2f;Commission=%.2f;Swap=%.2f",
                                 volume, price, profit, commission, swap);
   LogEvent("DEAL_" + symbol, details);
}

void UpdateDashboard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double start = DailyStartEquity();
   double lossPct = (start > 0.0) ? (start - equity) / start * 100.0 : 0.0;

   string status = "DISABLED - TEST FIRST";
   if(EnableTrading)
      status = EnvironmentAllowed() ? "ENABLED (DEMO ONLY)" : "BLOCKED";
   if(DailyLossLocked()) status = DailyBaselineTrusted ? "DAILY LOSS LOCK" : "BASELINE UNTRUSTED - NEW TRADES BLOCKED";

   Comment("===== GOLD HUNTER AI V3.4 =====\n",
           "Symbol: ", TradeSymbol, "\n",
           "Signal TF: M15 | Trend TF: H1\n",
           "Risk/trade: ", DoubleToString(RiskPercent, 2), "%\n",
           "Daily equity drawdown: ", DoubleToString(lossPct, 2), "%\n",
           "Daily limit: ", DoubleToString(DailyLossLimitPercent, 2), "%\n",
           "Balance: ", DoubleToString(balance, 2), "\n",
           "Equity: ", DoubleToString(equity, 2), "\n",
           "Status: ", status, "\n",
           "Daily baseline trusted: ", (DailyBaselineTrusted ? "YES" : "NO - TRADING BLOCKED"), "\n",
           "EnableTrading default: false");
}

void OnTick()
{
   UpdateDashboard();

   if(!EnvironmentAllowed()) return;
   if(DailyLossLocked()) return;
   if(AnyPositionOnSymbol()) return;
   if(!NewM15Bar()) return;
   if(!SpreadAcceptable()) return;

   int signal = GetSignal();
   if(signal != 0) OpenTrade(signal);
}
//+------------------------------------------------------------------+
