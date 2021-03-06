//+------------------------------------------------------------------+
//|                                      Collector(live)_v4.1.mq5 |
//+------------------------------------------------------------------+
#property copyright     "avoitenko & Lxbot"
#property version       "4.10"

#define DEBUG_PRINT     true

/*
Сов передает данные показателей индикаторов по сокету или в редис
Данные отправляються только если есть изменения по инструменту
период проверки изменений регулируеться в настройках InpUpdateMSec
*/

#include <libmysql.mqh>
#include <Arrays\ArrayString.mqh>
#include <Arrays\List.mqh>
#define MSVCRT_DLL
#include <redis.mqh>
#include <socket-library-mt4-mt5.mqh>

//+------------------------------------------------------------------+
input string InpSymbolsList="EURUSD_i;";//Список инструментов
input uint   InpUpdateMSec=250;//Период обновления, мсек
//---
input string redis_options="=== REDIS ===";
input bool   InpRedisUse=true;//Писать в REDIS
input string InpRedisHost="127.0.0.1";//REDIS IP адрес
input uint   InpRedisPort=6379;//REDIS порт
//---
input string socket_options="=== TCP Socket ===";
input bool   InpSocketUse=false;       //Писать в Socket
input string   Hostname = "127.0.0.1";    // Server hostname or IP address
input ushort   ServerPort = 9411;        // Server port
//+------------------------------------------------------------------+


// --------------------------------------------------------------------
// Global variables and constants
// --------------------------------------------------------------------

ClientSocket * glbClientSocket = NULL;

// --------------------------------------------------------------------
//--- класс для работы с инструментом
class CMyData : public CObject
  {
public:
   string            symbol;
   int               digits;
   double            close;

   int               rsi2_handle;
   int               rsi5_handle;
   int               rsi10_handle;
   int               rsi15_handle;
   int               rsi20_handle;
   int               rsi30_handle;
   int               rsi50_handle;
   int               rsi100_handle;
   int               rsi200_handle;
   int               rsi300_handle;

   //+------------------------------------------------------------------+
                     
   //+------------------------------------------------------------------+

  };
//---
CList list;
datetime wm_time_current=0;
int wm_symbols_total=0;
int csv_handle=INVALID_HANDLE;
int line_index=0;

CRedis redis;
string str_login=(string)AccountInfoInteger(ACCOUNT_LOGIN);
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int OnInit()
  {

   if(InpRedisUse)
      if(!redis.ConnectWithTimeout(InpRedisHost,InpRedisPort,3000))
        {
         Print("Init REDIS con serror:",redis.GetLastError());
         redis.Free();
        }

   CArrayString symbols;

   if(_UninitReason==REASON_PROGRAM ||    //старт программы
      _UninitReason==REASON_PARAMETERS)   //смена параметров
     {

      if(InpSymbolsList=="")
        {
         //--- все инструменты из Market Watch
         int total=SymbolsTotal(true);
         for(int i=0; i<total; i++)
           {
            string _symbol=SymbolName(i,true);
            if(!SymbolInfoInteger(_symbol,SYMBOL_CUSTOM) && symbols.SearchLinear(_symbol)==-1)
               symbols.Add(_symbol);
           }

         if(symbols.Total()==0)
            Print("Список инструментов пуст.");

        }
      else
        {
         //--- парсинг строки инструментов

         string symb_list=InpSymbolsList;
         StringReplace(symb_list,";"," ");
         StringReplace(symb_list,","," ");
         while(StringReplace(symb_list,"  "," ")>0);
         //---
         string result[];
         int total=StringSplit(symb_list,' ',result);
         for(int i=0; i<total; i++)
           {
            //--- проверка на пустую строку
            if(StringLen(result[i])==0)
               continue;
            //---         
            if(SymbolSelect(result[i],true))
              {
               if(symbols.SearchLinear(result[i])==-1)
                  symbols.Add(result[i]);
              }
            else
              {
               Print("Инструмент '",result[i],"' не найден.");
              }
           }
         //---
         if(symbols.Total()==0)
            Print("Список инструментов пуст.");
        }
     }

//--- добавление инструментов
   int total=symbols.Total();
   for(int i=0; i<total; i++)
     {
      string _symbol=symbols.At(i);
      //--- проверка, есть ли инструмент в списке

      bool found=false;
      int _total= list.Total();
      for(int k=0; k<_total; k++)
        {
         CMyData *item=list.GetNodeAtIndex(k);
         if(item.symbol==_symbol)
           {
            found=true;
            break;
           }
        }

      //--- добавление, если нет в списке
      if(!found)
        {
         if(DEBUG_PRINT)
            Print("Добавление ",_symbol," в список инструментов.");
         //---
         list.Add(new CMyData);
         CMyData *item=list.GetCurrentNode();
         item.symbol=_symbol;
         item.digits=(int)SymbolInfoInteger(_symbol,SYMBOL_DIGITS);

         item.rsi2_handle=iRSI(item.symbol,_Period,2,PRICE_CLOSE);
         item.rsi5_handle=iRSI(item.symbol,_Period,5,PRICE_CLOSE);
         item.rsi10_handle=iRSI(item.symbol,_Period,10,PRICE_CLOSE);
         item.rsi15_handle=iRSI(item.symbol,_Period,15,PRICE_CLOSE);
         item.rsi20_handle=iRSI(item.symbol,_Period,20,PRICE_CLOSE);
         item.rsi30_handle=iRSI(item.symbol,_Period,30,PRICE_CLOSE);
         item.rsi50_handle=iRSI(item.symbol,_Period,50,PRICE_CLOSE);
         item.rsi100_handle=iRSI(item.symbol,_Period,100,PRICE_CLOSE);
         item.rsi200_handle=iRSI(item.symbol,_Period,200,PRICE_CLOSE);
         item.rsi300_handle=iRSI(item.symbol,_Period,300,PRICE_CLOSE);

         if(item.rsi2_handle==INVALID_HANDLE ||
            item.rsi5_handle==INVALID_HANDLE ||
            item.rsi10_handle==INVALID_HANDLE ||
            item.rsi15_handle==INVALID_HANDLE ||
            item.rsi20_handle==INVALID_HANDLE ||
            item.rsi30_handle==INVALID_HANDLE ||
            item.rsi50_handle==INVALID_HANDLE ||
            item.rsi100_handle==INVALID_HANDLE ||
            item.rsi200_handle==INVALID_HANDLE ||
            item.rsi300_handle==INVALID_HANDLE)
           {
            Print("Неправильный хэндл индикатора для ",_symbol);
            return(INIT_FAILED);
           }
        }
     }

//--- удаление лишних инструментов (остались от предыдущих запусков/настроек)
   total=list.Total();
   for(int i=total-1; i>=0; i--)
     {
      CMyData *item=list.GetNodeAtIndex(i);
      if(symbols.SearchLinear(item.symbol)==-1)
        {
         //--- убрать из обзора рынка
         SymbolSelect(item.symbol,false);
         if(DEBUG_PRINT)
            Print("Удаление ",item.symbol," из списка инструментов.");
         list.Delete(i);
        }
     }

//---
   EventSetMillisecondTimer(InpUpdateMSec);

//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   redis.Free();

//--- удаляем хэндлы индикаторов
   int total=list.Total();
   for(int i=total-1; i>=0; i--)
     {
      CMyData *item=list.GetNodeAtIndex(i);
		IndicatorRelease(item.rsi2_handle);
      IndicatorRelease(item.rsi5_handle);
      IndicatorRelease(item.rsi10_handle);
      IndicatorRelease(item.rsi15_handle);
      IndicatorRelease(item.rsi20_handle);
      IndicatorRelease(item.rsi30_handle);
      IndicatorRelease(item.rsi50_handle);
      IndicatorRelease(item.rsi100_handle);
      IndicatorRelease(item.rsi200_handle);
      IndicatorRelease(item.rsi300_handle);
     }
//---
// Sockets Clean
   if (glbClientSocket) {
            delete glbClientSocket;
            glbClientSocket = NULL;
            }
//---
   list.Clear();

   if(csv_handle!=INVALID_HANDLE)
      FileClose(csv_handle);

   EventKillTimer();
  }
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return;

//--- обновление инструментов в обзоре рынка
//--- необходимо для работы индикаторов
   if(wm_time_current!=TimeCurrent() && wm_symbols_total!=SymbolsTotal(true))
     {
      wm_time_current=TimeCurrent();
      wm_symbols_total=SymbolsTotal(true);
      //---
      int total=list.Total();
      for(int i=0; i<total; i++)
        {
         CMyData *item=list.GetNodeAtIndex(i);
         SymbolSelect(item.symbol,true);
        }
     }

   MqlDateTime mdt;
   TimeToStruct(TimeCurrent(),mdt);

//--- записываем в базу данные одним запросом
   int index=0;
   int _total=list.Total();
   for(int k=0; k<_total; k++)
     {
      CMyData *item=list.GetNodeAtIndex(k);

      double bid=SymbolInfoDouble(item.symbol,SYMBOL_BID);

      if(fabs(bid-item.close)<_Point)
         continue;
      //Print(item.symbol," ",DoubleToString(item.close,item.digits)," -> ",DoubleToString(bid,item.digits));
      item.close=bid;

      //---
      MqlRates rates[];
      ArraySetAsSeries(rates,true);

      // ROC ----------------
      double ROC1[1]={0};
      double ROC2[1]={0};
      double ROC3[1]={0};
      double ROC4[1]={0};
      double ROC5[1]={0};
      double ROC6[1]={0};
      double ROC7[1]={0};
      double ROC8[1]={0};
      double ROC9[1]={0};
      double ROC10[1]={0};
      double ROC15[1]={0};
      double ROC30[1]={0};
      
      if(CopyRates(item.symbol,_Period,0,31,rates)==31)
        {
         if(rates[0].close!=0.0)
            {
            if(rates[0].close != rates[1].close) ROC1[0]=((rates[0].close - rates[1].close)/rates[0].close)*100000;
            if(rates[0].close != rates[2].close) ROC2[0]=((rates[0].close - rates[2].close)/rates[0].close)*100000;
            if(rates[0].close != rates[3].close) ROC3[0]=((rates[0].close - rates[3].close)/rates[0].close)*100000;
            if(rates[0].close != rates[4].close) ROC4[0]=((rates[0].close - rates[4].close)/rates[0].close)*100000;
            if(rates[0].close != rates[5].close) ROC5[0]=((rates[0].close - rates[5].close)/rates[0].close)*100000;
            if(rates[0].close != rates[6].close) ROC6[0]=((rates[0].close - rates[6].close)/rates[0].close)*100000;
            if(rates[0].close != rates[7].close) ROC7[0]=((rates[0].close - rates[7].close)/rates[0].close)*100000;
            if(rates[0].close != rates[8].close) ROC8[0]=((rates[0].close - rates[8].close)/rates[0].close)*100000;
            if(rates[0].close != rates[9].close) ROC9[0]=((rates[0].close - rates[9].close)/rates[0].close)*100000;
            if(rates[0].close != rates[10].close) ROC10[0]=((rates[0].close - rates[10].close)/rates[0].close)*100000;
            if(rates[0].close != rates[15].close) ROC15[0]=((rates[0].close - rates[15].close)/rates[0].close)*100000; 
            if(rates[0].close != rates[30].close) ROC30[0]=((rates[0].close - rates[30].close)/rates[0].close)*100000;
            }
        }

      // END ROC ----------------
            // Start SF ----------------


      // END SF ----------------
      
      // Start RSI
      double RSI2[1];
      if(CopyBuffer(item.rsi2_handle,0,0,1,RSI2)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI5[1];
      if(CopyBuffer(item.rsi5_handle,0,0,1,RSI5)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI10[1];
      if(CopyBuffer(item.rsi10_handle,0,0,1,RSI10)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI15[1];
      if(CopyBuffer(item.rsi15_handle,0,0,1,RSI15)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI20[1];
      if(CopyBuffer(item.rsi20_handle,0,0,1,RSI20)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI30[1];
      if(CopyBuffer(item.rsi30_handle,0,0,1,RSI30)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI50[1];
      if(CopyBuffer(item.rsi50_handle,0,0,1,RSI50)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI100[1];
      if(CopyBuffer(item.rsi100_handle,0,0,1,RSI100)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI200[1];
      if(CopyBuffer(item.rsi200_handle,0,0,1,RSI200)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      double RSI300[1];
      if(CopyBuffer(item.rsi300_handle,0,0,1,RSI300)!=1){Print("CopyBuffer RSI2 error ",_LastError);continue;}
      

      

      
      string json="{'Open':"+DoubleToString(rates[0].open,item.digits)+
                     ",'High':"+DoubleToString(rates[0].high,item.digits)+
                     ",'Low':"+DoubleToString(rates[0].low,item.digits)+
                     ",'Close':"+DoubleToString(rates[0].close,item.digits)+
                     ",'Tick_Volume':"+(string)rates[0].tick_volume+
                     ",'Spread':"+(string)SymbolInfoInteger(item.symbol,SYMBOL_SPREAD)+
                     //",'TimeCurrent':'"+TimeCurrent()+"'"+
                     //",'TimeLocal':'"+TimeLocal()+"'"+
                     ",'TimeLocal_Unix':"+DoubleToString(TimeLocal(),0)+","+
                      "'RSI_2':"+DoubleToString(RSI2[0],0)+","+
                      "'RSI_5':"+DoubleToString(RSI5[0],0)+","+
                      "'RSI_10':"+DoubleToString(RSI10[0],0)+","+
                      "'RSI_15':"+DoubleToString(RSI15[0],0)+","+
                      "'RSI_20':"+DoubleToString(RSI20[0],0)+","+
                      "'RSI_30':"+DoubleToString(RSI30[0],0)+","+
                      "'RSI_50':"+DoubleToString(RSI50[0],0)+","+
                      "'RSI_100':"+DoubleToString(RSI100[0],0)+","+
                      "'RSI_200':"+DoubleToString(RSI200[0],0)+","+
                      "'RSI_300':"+DoubleToString(RSI300[0],0)+","+
            
                      "'ROC_2':"+DoubleToString(ROC2[0],0)+","+
                      "'ROC_3':"+DoubleToString(ROC3[0],0)+","+
                      "'ROC_4':"+DoubleToString(ROC4[0],0)+","+
                      "'ROC_5':"+DoubleToString(ROC5[0],0)+","+
                      "'ROC_6':"+DoubleToString(ROC6[0],0)+","+
                      "'ROC_7':"+DoubleToString(ROC7[0],0)+","+
                      "'ROC_8':"+DoubleToString(ROC8[0],0)+","+
                      "'ROC_9':"+DoubleToString(ROC9[0],0)+","+
                      "'ROC_10':"+DoubleToString(ROC10[0],0)+","+
                      "'ROC_15':"+DoubleToString(ROC15[0],0)+","+
                      "'ROC_30':"+DoubleToString(ROC30[0],0)+", }";
      
      
      // Socket
      if(InpSocketUse)
         {
         //Print("Socket start");
         if (!glbClientSocket) 
            {
            glbClientSocket = new ClientSocket(Hostname, ServerPort);
            if (glbClientSocket.IsSocketConnected()) 
               {
               Print("Start Send Data");
               glbClientSocket.Send(json);
               }
            else {Print("Client connection failed");}
            }
            
         if (glbClientSocket) {
            delete glbClientSocket;
            glbClientSocket = NULL;
            }
         }
      
      // REDIS
      if(InpRedisUse)
        {
         //Print("Redis start");
         if(redis.GetLastError()==0)
           {
            ulong gmc=GetMicrosecondCount();
            //Print("REDIS Start Send");
            TReply reply;
            redis.Command("SET %s %s",item.symbol,json,reply);

            if(reply.type==REDIS_REPLY_ERROR)
              {
               Print("REDIS reply error: ",reply.str);
               break;
              }
            else if(reply.type==REDIS_REPLY_STATUS)
              {
               if(reply.str=="OK")
                  Comment("Last Update: "+(string)TimeLocal());
                  if (DEBUG_PRINT) Print("Записано REDIS ",item.symbol," ",DoubleToString((GetMicrosecondCount()-gmc)/1000.0,3)," мсек.");
               else
                  Print("status: ",reply.str);
              }
            else if(reply.type==REDIS_REPLY_STRING)
               Print("string: ",reply.str);
            else if(reply.type==REDIS_REPLY_INTEGER)
               Print("int: ",reply.integer);
            else if(reply.type==REDIS_REPLY_NIL)
               Print("nil");
           }
         else
           {
            if(!redis.ConnectWithTimeout(InpRedisHost,InpRedisPort,3000))
              {
               Print("REDIS con serror:",redis.GetLastError());
               redis.Free();
               break;
              }
           }
        }
     }

  }
//+------------------------------------------------------------------+
