--  The LCD's FT5336 capacitive touch panel (I2C3), polled. Only the first
--  touch point is used.

package Touch_Input is

   --  Start the touch controller. Call after Screen.Initialize. Never
   --  raises; on failure Available stays False and Read reports no touch.
   procedure Initialize;

   function Available return Boolean;

   type Touch_Sample is record
      Down : Boolean := False;
      X, Y : Natural := 0;   --  screen pixels, valid when Down
   end record;

   --  Current state of the first touch point. Never raises.
   function Read return Touch_Sample;

end Touch_Input;
