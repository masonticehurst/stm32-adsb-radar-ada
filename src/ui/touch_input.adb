with HAL.Touch_Panel;
with STM32.Board; use STM32.Board;

with Debug_Log;
with Screen;

package body Touch_Input is

   Ready : Boolean := False;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Ready := Touch_Panel.Initialize;

      if not Ready then
         Debug_Log.Put_Line ("touch: controller not found");
      end if;

   exception
      when others =>
         Ready := False;
         Debug_Log.Put_Line ("touch: start-up failed");
   end Initialize;

   ---------------
   -- Available --
   ---------------

   function Available return Boolean is (Ready);

   ----------
   -- Read --
   ----------

   function Read return Touch_Sample is
      use type HAL.Touch_Panel.TP_Touch_State;
      Point : HAL.Touch_Panel.TP_Touch_State;
   begin
      if not Ready or else Touch_Panel.Active_Touch_Points = 0 then
         return (Down => False, X => 0, Y => 0);
      end if;

      Point := Touch_Panel.Get_Touch_Point (1);

      --  Get_Touch_Point returns (0, 0, 0) if the finger lifted between
      --  the two reads or an I2C transfer failed
      if Point = HAL.Touch_Panel.Null_Touch_State then
         return (Down => False, X => 0, Y => 0);
      end if;

      return
        (Down => True, X => Natural'Min (Point.X, Screen.Width - 1),
         Y    => Natural'Min (Point.Y, Screen.Height - 1));

   exception
      when others =>
         return (Down => False, X => 0, Y => 0);
   end Read;

end Touch_Input;
