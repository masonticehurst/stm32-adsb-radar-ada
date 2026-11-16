--  The 480x272 LCD as two LTDC layers, each double-buffered:
--     layer 1: map tiles (RGB565, opaque)
--     layer 2: range rings, own ship, traffic and text (ARGB4444, mostly
--              transparent so the map shows through)
--  Draw into the hidden buffers, then call Show to display both at once.

with HAL.Bitmap;

package Screen is

   Width    : constant := 480;
   Height   : constant := 272;
   Centre_X : constant := Width / 2;
   Centre_Y : constant := Height / 2;

   --  Starts the LCD, SDRAM and DMA2D. Call before anything else that uses
   --  the screen or SDRAM.
   procedure Initialize;

   --  Hidden (back) buffers. Every frame redraws both completely.
   function Map_Layer return HAL.Bitmap.Any_Bitmap_Buffer;
   function Overlay_Layer return HAL.Bitmap.Any_Bitmap_Buffer;

   --  Display both hidden buffers
   procedure Show;

end Screen;
