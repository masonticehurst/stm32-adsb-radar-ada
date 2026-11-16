with HAL.Bitmap; use HAL.Bitmap;

with Screen;

package body Controls is

   Size      : constant := 52;   --  button width and height, pixels
   Margin    : constant := 6;    --  gap to the screen edge
   Touch_Pad : constant := 6;    --  extra touch area around each button
   Radius    : constant := 8;    --  corner radius

   Column_X   : constant := Screen.Width - Size - Margin;
   Zoom_In_Y  : constant := 34;
   Zoom_Out_Y : constant := Zoom_In_Y + Size + 10;
   Centre_Y   : constant := Screen.Height - Size - 16;

   Fill_Color : constant Bitmap_Color :=
     (Alpha => 190, Red => 20, Green => 24, Blue => 32);
   Enabled_Color  : constant Bitmap_Color := White;
   Disabled_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 100, Green => 100, Blue => 100);
   Centre_Color : constant Bitmap_Color :=
     (Alpha => 255, Red => 0, Green => 200, Blue => 255);

   function Top_Of (C : Control) return Natural is
     (case C is when Zoom_In   => Zoom_In_Y, when Zoom_Out => Zoom_Out_Y,
        when Centre_On_Ownship => Centre_Y, when None => 0);

   ---------
   -- Hit --
   ---------

   function Hit (X, Y : Natural) return Control is
   begin
      if X + Touch_Pad < Column_X then
         return None;
      end if;

      for C in Zoom_In .. Centre_On_Ownship loop
         if Y + Touch_Pad >= Top_Of (C)
           and then Y <= Top_Of (C) + Size + Touch_Pad
         then
            return C;
         end if;
      end loop;

      return None;
   end Hit;

   -----------------
   -- Draw_Button --
   -----------------

   procedure Draw_Button
     (Buffer : Any_Bitmap_Buffer; C : Control; Color : Bitmap_Color)
   is
      Y    : constant Natural := Top_Of (C);
      Area : constant Rect    := ((Column_X, Y), Size, Size);
      CX   : constant Natural := Column_X + Size / 2;
      CY   : constant Natural := Y + Size / 2;
   begin
      Buffer.Set_Source (Fill_Color);
      Buffer.Fill_Rounded_Rect (Area, Radius);

      Buffer.Set_Source (Color);
      Buffer.Draw_Rounded_Rect (Area, Radius, Thickness => 2);

      case C is
         when Zoom_In =>
            Buffer.Fill_Rect (((CX - 12, CY - 2), 24, 4));
            Buffer.Fill_Rect (((CX - 2, CY - 12), 4, 24));

         when Zoom_Out =>
            Buffer.Fill_Rect (((CX - 12, CY - 2), 24, 4));

         when Centre_On_Ownship =>
            --  Target: ring, four ticks and a centre dot
            Buffer.Draw_Circle ((CX, CY), 10);
            Buffer.Draw_Circle ((CX, CY), 9);
            Buffer.Fill_Rect (((CX - 16, CY - 1), 6, 3));
            Buffer.Fill_Rect (((CX + 11, CY - 1), 6, 3));
            Buffer.Fill_Rect (((CX - 1, CY - 16), 3, 6));
            Buffer.Fill_Rect (((CX - 1, CY + 11), 3, 6));
            Buffer.Fill_Circle ((CX, CY), 2);

         when None =>
            null;
      end case;
   end Draw_Button;

   ----------
   -- Draw --
   ----------

   procedure Draw
     (Buffer       : Any_Bitmap_Buffer; Can_Zoom_In : Boolean;
      Can_Zoom_Out : Boolean; Off_Ownship : Boolean)
   is
   begin
      Draw_Button
        (Buffer, Zoom_In,
         (if Can_Zoom_In then Enabled_Color else Disabled_Color));
      Draw_Button
        (Buffer, Zoom_Out,
         (if Can_Zoom_Out then Enabled_Color else Disabled_Color));
      Draw_Button
        (Buffer, Centre_On_Ownship,
         (if Off_Ownship then Centre_Color else Disabled_Color));
   end Draw;

end Controls;
