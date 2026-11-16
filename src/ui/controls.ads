--  On-screen touch buttons, stacked down the right-hand edge:
--     "+"       zoom in  (halve the range)
--     "-"       zoom out (double the range)
--     centre    recentre the map on own ship (lit after the map was panned)

with HAL.Bitmap;

package Controls is

   type Control is (None, Zoom_In, Zoom_Out, Centre_On_Ownship);

   --  Button under screen point (X, Y). Touch areas are a little larger
   --  than the drawn buttons.
   function Hit (X, Y : Natural) return Control;

   --  Draw all buttons. Buttons that would do nothing are greyed out.
   procedure Draw
     (Buffer       : HAL.Bitmap.Any_Bitmap_Buffer; Can_Zoom_In : Boolean;
      Can_Zoom_Out : Boolean; Off_Ownship : Boolean);

end Controls;
