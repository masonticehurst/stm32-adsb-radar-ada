--  Screenshots to the SD card, taken with the blue USER button.
--
--  Saves exactly what is on the LCD as a 24-bit BMP, SHOTnnnn.BMP in the
--  card's root (the first unused number). The picture is made the way the
--  LTDC makes it: the visible map buffer (layer 1, RGB565) with the
--  visible overlay buffer (layer 2, ARGB4444) blended on top by its pixel
--  alpha. Call from the main loop between frames, so the screen cannot
--  change while it is read.
--
--  Writing takes about 2 seconds (1.8 s measured), during which the
--  display and touch freeze; serial bytes that arrive meanwhile may be
--  lost (counted by the UART drivers).

package Screenshot is

   --  Save the current screen to the card. Saved is False if it could not
   --  be saved. Logs the file name and time taken, or why it failed, on the
   --  debug port. Never raises.
   procedure Save (Saved : out Boolean);

   --  Name of the last file saved, e.g. "SHOT0003.BMP" (blank before the
   --  first)
   function Last_File return String;

end Screenshot;
