with Ada.Numerics;
with Ada.Numerics.Long_Elementary_Functions;
use Ada.Numerics.Long_Elementary_Functions;

package body Geo is

   Pi : constant := Ada.Numerics.Pi;

   --  Ground metres per pixel at the equator at zoom 0 (WGS 84 equatorial
   --  circumference / 256)
   Equator_M_Per_Px : constant := 156_543.033_92;
   Metres_Per_NM    : constant := 1_852.0;

   function Radians (Deg : Long_Float) return Long_Float is (Deg * Pi / 180.0);

   function Clamp_Lat (Lat : Latitude) return Long_Float is
     (Long_Float'Max
        (-Max_Mercator_Lat, Long_Float'Min (Max_Mercator_Lat, Lat)));

   --------------------
   -- To_World_Pixel --
   --------------------

   function To_World_Pixel (P : Position; Zoom : Zoom_Level) return World_Pixel
   is
      Size   : constant Long_Float := 256.0 * 2.0**Zoom;
      Phi    : constant Long_Float := Radians (Clamp_Lat (P.Lat));
      Merc_Y : constant Long_Float := Log (Tan (Phi) + 1.0 / Cos (Phi));
   begin
      return
        (X => (P.Lon + 180.0) / 360.0 * Size,
         Y => (1.0 - Merc_Y / Pi) / 2.0 * Size);
   end To_World_Pixel;

   ----------------------
   -- From_World_Pixel --
   ----------------------

   function From_World_Pixel
     (P : World_Pixel; Zoom : Zoom_Level) return Position
   is
      Size : constant Long_Float := 256.0 * 2.0**Zoom;
      X    : constant Long_Float :=
        Long_Float'Max (0.0, Long_Float'Min (Size, P.X));
      Y : constant Long_Float :=
        Long_Float'Max (0.0, Long_Float'Min (Size, P.Y));
      Lat : constant Long_Float :=
        Arctan (Sinh (Pi * (1.0 - 2.0 * Y / Size))) * 180.0 / Pi;
   begin
      return
        (Lat => Clamp_Lat (Lat),
         Lon =>
           Long_Float'Max
             (-180.0, Long_Float'Min (180.0, X / Size * 360.0 - 180.0)));
   end From_World_Pixel;

   -------------------
   -- Pixels_Per_NM --
   -------------------

   function Pixels_Per_NM (Lat : Latitude; Zoom : Zoom_Level) return Long_Float
   is
      M_Per_Px : constant Long_Float :=
        Equator_M_Per_Px * Cos (Radians (Clamp_Lat (Lat))) / 2.0**Zoom;
   begin
      return Metres_Per_NM / M_Per_Px;
   end Pixels_Per_NM;

   --  Mean Earth radius in nautical miles
   Earth_Radius_NM : constant := 3_440.065;

   -----------------
   -- Distance_NM --
   -----------------

   function Distance_NM (From, To : Position) return Long_Float is
      Phi_1 : constant Long_Float := Radians (From.Lat);
      Phi_2 : constant Long_Float := Radians (To.Lat);
      D_Phi : constant Long_Float := Radians (To.Lat - From.Lat);
      D_Lam : constant Long_Float := Radians (To.Lon - From.Lon);
      A     : constant Long_Float :=
        Sin (D_Phi / 2.0)**2 +
        Cos (Phi_1) * Cos (Phi_2) * Sin (D_Lam / 2.0)**2;
   begin
      return
        Earth_Radius_NM * 2.0 *
        Arctan (Sqrt (A), Sqrt (Long_Float'Max (0.0, 1.0 - A)));
   end Distance_NM;

   -----------------
   -- Bearing_Deg --
   -----------------

   function Bearing_Deg (From, To : Position) return Long_Float is
      Phi_1 : constant Long_Float := Radians (From.Lat);
      Phi_2 : constant Long_Float := Radians (To.Lat);
      D_Lam : constant Long_Float := Radians (To.Lon - From.Lon);
      Y     : constant Long_Float := Sin (D_Lam) * Cos (Phi_2);
      X     : constant Long_Float :=
        Cos (Phi_1) * Sin (Phi_2) - Sin (Phi_1) * Cos (Phi_2) * Cos (D_Lam);
      Deg : Long_Float;
   begin
      if X = 0.0 and then Y = 0.0 then
         return 0.0;  --  same point
      end if;

      Deg := Arctan (Y, X) * 180.0 / Pi;
      return (if Deg < 0.0 then Deg + 360.0 else Deg);
   end Bearing_Deg;

end Geo;
