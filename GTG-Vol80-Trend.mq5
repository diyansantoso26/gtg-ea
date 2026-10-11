//+------------------------------------------------------------------+
//|                                              GTG-Vol80-Trend.mq5 |
//|                                                    GTG Computer |
//|        Trend-following EA untuk VOL_80 (Headway, MT5, MQL5)       |
//+------------------------------------------------------------------+
#property copyright "GTG Computer"
#property link      "https://gtgcomputer.github.io"
#property version   "1.00"
#property description "Trend-following EA: EMA fast/slow + ADX + DI, SL/TP berbasis ATR."
#property description "Fitur profesional: lot dari % risiko, trailing stop, break-even,"
#property description "filter spread, batas rugi harian, max 1 posisi, magic number."

#include <Trade\Trade.mqh>

//--- mode trading
enum ENUM_GTG_MODE
  {
   MODE_BOTH = 0,   // Buy & Sell
   MODE_BUY  = 1,   // Buy saja
   MODE_SELL = 2    // Sell saja
  };

input group "=== Trend Filter ==="
input int               InpFastMA       = 20;            // Fast EMA
input int               InpSlowMA       = 50;            // Slow EMA
input int               InpADXPeriod    = 14;            // Periode ADX
input double            InpADXMin       = 25.0;          // ADX minimum
input group "=== ATR untuk SL/TP ==="
input int               InpATRPeriod    = 14;            // Periode ATR
input double            InpSL_ATR       = 2.0;           // SL = x ATR
input double            InpTP_ATR       = 3.0;           // TP = x ATR
input group "=== Risiko ==="
input double            InpRiskPct      = 1.0;           // Risiko per trade (% equity)
input double            InpDailyLossPct = 3.0;           // Batas rugi harian (% / 0=mati)
input ENUM_GTG_MODE     InpMode         = MODE_BOTH;     // Arah trading
input group "=== Manajemen Posisi ==="
input bool              InpUseTrailing  = true;          // Trailing stop aktif
input double            InpTrailStart   = 1.5;           // Mulai trailing stlh x ATR profit
input double            InpTrailDist    = 0.5;           // Jarak trailing x ATR
input bool              InpUseBE        = true;          // Break-even aktif
input double            InpBEStart      = 1.0;           // BE setelah x ATR profit
input int               InpBEOffsetPts = 10;            // Offset BE (point)
input group "=== Filter & Eksekusi ==="
input int               InpMaxSpread   = 50;            // Spread maks (point)
input int               InpSlippage    = 20;            // Slippage maks (point)
input long              InpMagic        = 801980;        // Magic number
input ENUM_TIMEFRAMES   InpTF           = PERIOD_M15;    // Timeframe sinyal

//--- global
CTrade   g_trade;
int      g_hFast = INVALID_HANDLE, g_hSlow = INVALID_HANDLE;
int      g_hADX  = INVALID_HANDLE, g_hATR  = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_today   = 0;
double   g_dayEquity = 0.0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFastMA >= InpSlowMA)
     { Print("Input salah: FastMA harus lebih kecil dari SlowMA"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRiskPct <= 0 || InpRiskPct > 10)
     { Print("Input salah: RiskPct 0.1 - 10"); return(INIT_PARAMETERS_INCORRECT); }

   g_hFast = iMA(_Symbol, InpTF, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, InpTF, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hADX  = iADX(_Symbol, InpTF, InpADXPeriod);
   g_hATR  = iATR(_Symbol, InpTF, InpATRPeriod);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE ||
      g_hADX == INVALID_HANDLE  || g_hATR == INVALID_HANDLE)
     { Print("Gagal membuat indicator handle"); return(INIT_FAILED); }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   Print("GTG Vol80 Trend v1.00 aktif di ", _Symbol, " TF=", EnumToString(InpTF));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { Comment(""); }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Ambil 2 nilai terakhir (shift 1 & 2) dari indicator handle        |
//+------------------------------------------------------------------+
bool GetInd(const int handle, const int buffer, double &v1, double &v2)
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, buffer, 1, 2, buf) < 2) return(false);
   v1 = buf[0]; v2 = buf[1];
   return(true);
  }

//+------------------------------------------------------------------+
//| Cari posisi milik EA ini (symbol + magic)                         |
//+------------------------------------------------------------------+
bool GetMyPosition(ulong &ticket, long &ptype, double &open, double &sl, double &tp)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
        {
         ticket = tk;
         ptype  = PositionGetInteger(POSITION_TYPE);
         open   = PositionGetDouble(POSITION_PRICE_OPEN);
         sl     = PositionGetDouble(POSITION_SL);
         tp     = PositionGetDouble(POSITION_TP);
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Hitung lot dari % risiko terhadap jarak SL                        |
//+------------------------------------------------------------------+
double CalcLot(const double entry, const double slPrice)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slDist    = MathAbs(entry - slPrice);
   if(tickVal <= 0 || tickSize <= 0 || slDist <= 0 || riskMoney <= 0) return(0.0);

   double lossPerLot = slDist / tickSize * tickVal;
   double lot = riskMoney / lossPerLot;

   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int lotDigits = (step < 1.0) ? (int)MathCeil(-MathLog10(step)) : 0;
   lot = MathFloor(lot / step + 1e-8) * step;
   lot = MathMin(MathMax(lot, minV), maxV);
   return(NormalizeDouble(lot, lotDigits));
  }

//+------------------------------------------------------------------+
//| Sinyal trend: +1 buy, -1 sell, 0 tidak ada                        |
//+------------------------------------------------------------------+
int GetSignal(double &atrOut, double &adxOut)
  {
   double f1, f2, s1, s2, adx1, adx2, pdi1, pdi2, mdi1, mdi2, atr1, atr2;
   if(!GetInd(g_hFast, 0, f1, f2)) return(0);
   if(!GetInd(g_hSlow, 0, s1, s2)) return(0);
   if(!GetInd(g_hADX, 0, adx1, adx2)) return(0);
   if(!GetInd(g_hADX, 1, pdi1, pdi2)) return(0);
   if(!GetInd(g_hADX, 2, mdi1, mdi2)) return(0);
   if(!GetInd(g_hATR, 0, atr1, atr2)) return(0);
   atrOut = atr1; adxOut = adx1;
   if(atr1 <= 0) return(0);

   double close1 = iClose(_Symbol, InpTF, 1);
   if(close1 <= 0) return(0);

   bool upTrend   = (f1 > s1) && (pdi1 > mdi1) && (adx1 >= InpADXMin) && (close1 > f1);
   bool downTrend = (f1 < s1) && (mdi1 > pdi1) && (adx1 >= InpADXMin) && (close1 < f1);

   if(upTrend   && InpMode != MODE_SELL) return(1);
   if(downTrend && InpMode != MODE_BUY)  return(-1);
   return(0);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Kelola posisi: break-even dulu, lalu trailing stop                |
//+------------------------------------------------------------------+
void ManagePosition(const ulong ticket, const long ptype, const double open,
                    const double sl, const double tp)
  {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_hATR, 0, 0, 1, atrBuf) < 1 || atrBuf[0] <= 0) return;
   double atrCur = atrBuf[0];

   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool isBuy = (ptype == POSITION_TYPE_BUY);

   //--- 1) Break-even
   if(InpUseBE)
     {
      double profitDist = isBuy ? (bid - open) : (open - ask);
      if(profitDist >= InpBEStart * atrCur)
        {
         double beSL = isBuy ? open + InpBEOffsetPts * point
                             : open - InpBEOffsetPts * point;
         bool needBE = isBuy ? (sl < beSL - point) : (sl > beSL + point || sl == 0);
         double curPx = isBuy ? bid : ask;
         bool distOK  = isBuy ? (curPx - beSL >= minDist) : (beSL - curPx >= minDist);
         if(needBE && distOK)
            g_trade.PositionModify(ticket, NormalizeDouble(beSL, digits), tp);
        }
     }

   //--- 2) Trailing stop
   if(InpUseTrailing)
     {
      double profitDist = isBuy ? (bid - open) : (open - ask);
      if(profitDist >= InpTrailStart * atrCur)
        {
         double trailDist = InpTrailDist * atrCur;
         double newSL = isBuy ? bid - trailDist : ask + trailDist;
         bool better  = isBuy ? (newSL > sl + point) : (sl == 0 || newSL < sl - point);
         double curPx = isBuy ? bid : ask;
         bool distOK  = isBuy ? (curPx - newSL >= minDist) : (newSL - curPx >= minDist);
         if(better && distOK)
            g_trade.PositionModify(ticket, NormalizeDouble(newSL, digits), tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- EA diizinkan trading?
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     { Comment("GTG Vol80: Algo Trading MATI / akun tidak boleh trade"); return; }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- reset harian
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart != g_today) { g_today = dayStart; g_dayEquity = equity; }
   bool dailyStop = (InpDailyLossPct > 0 && g_dayEquity > 0 &&
                     equity <= g_dayEquity * (1.0 - InpDailyLossPct / 100.0));

   //--- kelola posisi yang ada
   ulong ticket; long ptype; double open, sl, tp;
   bool hasPos = GetMyPosition(ticket, ptype, open, sl, tp);
   if(hasPos) ManagePosition(ticket, ptype, open, sl, tp);

   //--- status panel
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atrNow = 0, adxNow = 0;
   GetSignal(atrNow, adxNow);   // hanya untuk tampilan
   string state = dailyStop ? "DAILY STOP: tidak entry hari ini" :
                  hasPos    ? "Posisi terbuka: trailing/BE aktif" :
                              "Menunggu sinyal (entry tiap bar baru)";
   Comment(StringFormat(
      "GTG Vol80 Trend v1.00  |  %s %s\n" +
      "Equity: %.2f   |   P/L hari ini: %+.2f\n" +
      "Spread: %d pt (maks %d)   |   ADX: %.1f (min %.0f)\n%s",
      _Symbol, EnumToString(InpTF),
      equity, equity - g_dayEquity,
      spread, InpMaxSpread, adxNow, InpADXMin, state));

   //--- hanya entry di bar baru, tanpa posisi, tanpa daily stop
   datetime curBar = iTime(_Symbol, InpTF, 0);
   bool isNewBar = (curBar != g_lastBar);
   if(!isNewBar || hasPos || dailyStop) return;
   g_lastBar = curBar;

   if(spread > InpMaxSpread) return;

   double atr1, adx1;
   int sig = GetSignal(atr1, adx1);
   if(sig == 0) return;

   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry = (sig > 0) ? ask : bid;
   double slPrice, tpPrice;
   if(sig > 0)
     {
      slPrice = entry - atr1 * InpSL_ATR;
      if(entry - slPrice < minDist) slPrice = entry - minDist;
      tpPrice = entry + atr1 * InpTP_ATR;
     }
   else
     {
      slPrice = entry + atr1 * InpSL_ATR;
      if(slPrice - entry < minDist) slPrice = entry + minDist;
      tpPrice = entry - atr1 * InpTP_ATR;
     }
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);

   double lot = CalcLot(entry, slPrice);
   if(lot <= 0) { Print("Lot tidak valid, entry dibatalkan"); return; }

   double margin;
   if(!OrderCalcMargin(sig > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       _Symbol, lot, entry, margin) ||
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     { Print("Margin tidak cukup untuk lot ", lot); return; }

   bool ok;
   if(sig > 0)
      ok = g_trade.Buy(lot, _Symbol, 0.0, slPrice, tpPrice, "GTG Vol80 Buy");
   else
      ok = g_trade.Sell(lot, _Symbol, 0.0, slPrice, tpPrice, "GTG Vol80 Sell");

   if(!ok)
      Print("Order gagal: ", g_trade.ResultRetcode(), " ",
            g_trade.ResultRetcodeDescription());
   else
      Print("Order terkirim: ", (sig > 0 ? "BUY" : "SELL"),
            " lot=", lot, " SL=", slPrice, " TP=", tpPrice);
  }
//+------------------------------------------------------------------+
