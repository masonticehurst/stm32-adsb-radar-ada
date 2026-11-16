--  Debug logging over the ST-LINK virtual COM port (USART1 TX on PA9).
--  Adapted from Serial_Log in assignment 2.

package Debug_Log is

   Baud_Rate : constant := 115_200;

   procedure Initialize;
   procedure Put_Line (Line : String);

end Debug_Log;
