//+------------------------------------------------------------------+
//| GOLD HUNTER AI V4 - fresh demo-first restart                     |
//| Compile and test in MetaTrader 5 before any live use.             |
//+------------------------------------------------------------------+
#property strict
#property version "4.00"
#property description "Structure-confirmed, multi-timeframe trend EA"
#include <Trade\Trade.mqh>
CTrade trade;

input string InpSymbol="";                 // Blank = chart symbol
input bool EnableTrading=false;             // Safety: OFF until verified
input bool DemoOnly=true;                   // Safety: block real accounts
input double RiskPercent=0.50;              // Equity risk per trade
input double DailyLossLimitPercent=2.0;
input double RewardRiskRatio=1.5;
input double ATRStopMultiplier=2.0;
input double ATRTrailMultiplier=1.5;
input int ATRPeriod=14;
input int FastEMA=20;
input int SlowEMA=50;
input int RSIPeriod=14;
input int StructureLookback=12;
input int MaxSpreadPoints=150;
input int SlippagePoints=20;
input ulong MagicNumber=20261012;

string sym;
int fast15=INVALID_HANDLE,slow15=INVALID_HANDLE,fastH1=INVALID_HANDLE,slowH1=INVALID_HANDLE,atrH=INVALID_HANDLE,rsiH=INVALID_HANDLE;
datetime lastBar=0;
double dayStartEquity=0.0;
int dayKey=-1;
bool dayLocked=false;

int DateKey(){ MqlDateTime d; TimeToStruct(TimeCurrent(),d); return d.year*10000+d.mon*100+d.day; }
bool Buf(int h,int shift,double &v){ double a[1]; if(h==INVALID_HANDLE||BarsCalculated(h)<=shift)return false; if(CopyBuffer(h,0,shift,1,a)!=1)return false; v=a[0]; return MathIsValidNumber(v); }
bool NewBar(){ datetime t=iTime(sym,PERIOD_M15,0); if(t<=0||t==lastBar)return false; lastBar=t; return true; }
bool DemoAccount(){ return (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO; }
bool DailyGuard(){ int today=DateKey(); if(today!=dayKey){dayKey=today;dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);dayLocked=false;} if(dayStartEquity<=0)return true; if((dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))/dayStartEquity*100.0>=DailyLossLimitPercent)dayLocked=true; return dayLocked; }
bool SpreadOK(){ MqlTick t; double p=SymbolInfoDouble(sym,SYMBOL_POINT); if(p<=0||!SymbolInfoTick(sym,t))return false; return (t.ask-t.bid)/p<=MaxSpreadPoints; }
bool AnyPositionOnSymbol(){ for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t>0&&PositionGetString(POSITION_SYMBOL)==sym)return true;}return false; }
bool OurPosition(ulong &ticket,ENUM_POSITION_TYPE &type,double &sl,double &tp){ for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||PositionGetString(POSITION_SYMBOL)!=sym)continue;if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;ticket=t;type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);sl=PositionGetDouble(POSITION_SL);tp=PositionGetDouble(POSITION_TP);return true;}return false; }

// +1 BUY, -1 SELL, 0 NO TRADE. Uses H1 bias, M15 alignment, closed-bar
// EMA reclaim, RSI momentum and a recent swing-room filter.
int Signal(){
 double fh,sh,fm,sm,rsi,atr;
 if(!Buf(fastH1,1,fh)||!Buf(slowH1,1,sh)||!Buf(fast15,1,fm)||!Buf(slow15,1,sm)||!Buf(rsiH,1,rsi)||!Buf(atrH,1,atr)||atr<=0)return 0;
 double c1=iClose(sym,PERIOD_M15,1),c2=iClose(sym,PERIOD_M15,2),o1=iOpen(sym,PERIOD_M15,1); if(c1<=0||c2<=0||o1<=0)return 0;
 int hs=iHighest(sym,PERIOD_M15,MODE_HIGH,StructureLookback,2),ls=iLowest(sym,PERIOD_M15,MODE_LOW,StructureLookback,2);if(hs<0||ls<0)return 0;
 double hi=iHigh(sym,PERIOD_M15,hs),lo=iLow(sym,PERIOD_M15,ls);
 bool buy=(fh>sh&&fm>sm&&c2<=fm&&c1>fm&&c1>o1&&rsi>=50&&rsi<=70&&hi-c1>atr*0.25);
 bool sell=(fh<sh&&fm<sm&&c2>=fm&&c1<fm&&c1<o1&&rsi<=50&&rsi>=30&&c1-lo>atr*0.25);
 if(buy)return 1;if(sell)return -1;return 0;
}
double VolumeForRisk(ENUM_ORDER_TYPE ot,double entry,double stop){
 double eq=AccountInfoDouble(ACCOUNT_EQUITY),risk=eq*RiskPercent/100.0,pnl=0;if(eq<=0||risk<=0||!OrderCalcProfit(ot,sym,1.0,entry,stop,pnl))return 0;
 double loss=MathAbs(pnl),step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP),minv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN),maxv=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);if(loss<=0||step<=0||minv<=0||maxv<=0)return 0;
 double v=MathFloor(MathMin(risk/loss,maxv)/step+1e-9)*step;if(v<minv)return 0;return NormalizeDouble(v,2);
}
void OpenTrade(int s){
 MqlTick t;double atr;if(!SymbolInfoTick(sym,t)||!Buf(atrH,1,atr)||atr<=0)return;
 double point=SymbolInfoDouble(sym,SYMBOL_POINT);int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);if(point<=0)return;
 double entry=s>0?t.ask:t.bid;double dist=MathMax(atr*ATRStopMultiplier,(SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL)+2)*point);
 double sl=NormalizeDouble(s>0?entry-dist:entry+dist,digits),tp=NormalizeDouble(s>0?entry+dist*RewardRiskRatio:entry-dist*RewardRiskRatio,digits);
 ENUM_ORDER_TYPE ot=s>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL;double vol=VolumeForRisk(ot,entry,sl);if(vol<=0){Print("Entry rejected: volume/risk invalid or below broker minimum.");return;}
 bool ok=s>0?trade.Buy(vol,sym,0,sl,tp,"GHV4 confirmed BUY"):trade.Sell(vol,sym,0,sl,tp,"GHV4 confirmed SELL");uint rc=trade.ResultRetcode();
 if(!ok||(rc!=TRADE_RETCODE_DONE&&rc!=TRADE_RETCODE_PLACED&&rc!=TRADE_RETCODE_DONE_PARTIAL))Print("Order failed: ",rc," ",trade.ResultRetcodeDescription());
}
void ManagePosition(){
 ulong ticket;ENUM_POSITION_TYPE type;double sl,tp;if(!OurPosition(ticket,type,sl,tp))return;int sig=Signal();
 if((type==POSITION_TYPE_BUY&&sig<0)||(type==POSITION_TYPE_SELL&&sig>0)){if(!trade.PositionClose(ticket))Print("Close failed: ",trade.ResultRetcodeDescription());return;}
 double atr;MqlTick t;if(!Buf(atrH,1,atr)||!SymbolInfoTick(sym,t))return;double point=SymbolInfoDouble(sym,SYMBOL_POINT);int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);if(point<=0)return;
 if(type==POSITION_TYPE_BUY){double n=NormalizeDouble(t.bid-atr*ATRTrailMultiplier,digits);if(n>sl+point&&n<t.bid&&!trade.PositionModify(ticket,n,tp))Print("BUY trail update failed: ",trade.ResultRetcodeDescription());}
 else{double n=NormalizeDouble(t.ask+atr*ATRTrailMultiplier,digits);if((sl==0||n<sl-point)&&n>t.ask&&!trade.PositionModify(ticket,n,tp))Print("SELL trail update failed: ",trade.ResultRetcodeDescription());}
}
int OnInit(){
 sym=InpSymbol==""?_Symbol:InpSymbol;if(!SymbolSelect(sym,true))return INIT_FAILED;
 if(RiskPercent<=0||RiskPercent>5||DailyLossLimitPercent<=0||RewardRiskRatio<=0||ATRStopMultiplier<=0||ATRTrailMultiplier<=0||FastEMA<2||SlowEMA<=FastEMA||ATRPeriod<2||RSIPeriod<2||StructureLookback<4||MaxSpreadPoints<0)return INIT_PARAMETERS_INCORRECT;
 fast15=iMA(sym,PERIOD_M15,FastEMA,0,MODE_EMA,PRICE_CLOSE);slow15=iMA(sym,PERIOD_M15,SlowEMA,0,MODE_EMA,PRICE_CLOSE);fastH1=iMA(sym,PERIOD_H1,FastEMA,0,MODE_EMA,PRICE_CLOSE);slowH1=iMA(sym,PERIOD_H1,SlowEMA,0,MODE_EMA,PRICE_CLOSE);atrH=iATR(sym,PERIOD_M15,ATRPeriod);rsiH=iRSI(sym,PERIOD_M15,RSIPeriod,PRICE_CLOSE);
 if(fast15==INVALID_HANDLE||slow15==INVALID_HANDLE||fastH1==INVALID_HANDLE||slowH1==INVALID_HANDLE||atrH==INVALID_HANDLE||rsiH==INVALID_HANDLE)return INIT_FAILED;
 trade.SetExpertMagicNumber(MagicNumber);
 trade.SetDeviationInPoints(SlippagePoints);
 dayKey=DateKey();
 dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
 dayLocked=false;
 Print("GH V4 initialized; trading ",EnableTrading?"enabled":"DISABLED by default",". Compile, backtest and demo-test before live use.");return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){if(fast15!=INVALID_HANDLE)IndicatorRelease(fast15);if(slow15!=INVALID_HANDLE)IndicatorRelease(slow15);if(fastH1!=INVALID_HANDLE)IndicatorRelease(fastH1);if(slowH1!=INVALID_HANDLE)IndicatorRelease(slowH1);if(atrH!=INVALID_HANDLE)IndicatorRelease(atrH);if(rsiH!=INVALID_HANDLE)IndicatorRelease(rsiH);}
void OnTick(){
 if(DailyGuard())return;if(!NewBar())return;ManagePosition();
 if(!EnableTrading||!TerminalInfoInteger(TERMINAL_CONNECTED)||!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED)||!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))return;
 if(DemoOnly&&!DemoAccount())return;if(!SpreadOK()||AnyPositionOnSymbol())return;int s=Signal();if(s!=0)OpenTrade(s);
}
