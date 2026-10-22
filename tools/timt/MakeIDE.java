// Create an IDE hard disk image (Nouspikel IDE / Geneve) with one partition, the way TIImageTool's
// "New IDE image" action does (de.mizapf.timt.ui.NewIDEImageAction, Michael Zapf, GPL-3), without the GUI.
//
//   java -cp <timt classes> de.mizapf.timt.ui.MakeIDE OUT.(chd|raw) SIZE_MB VOLUMENAME
//
// Files are then added with TIImageTool's command shell: CommandShell import OUT IDE1 (from a directory
// of TIFILES files).
package de.mizapf.timt.ui;

import java.io.File;
import de.mizapf.timt.TIImageTool;
import de.mizapf.timt.files.*;
import de.mizapf.timt.util.*;

public class MakeIDE {
    public static void main(String[] arg) throws Exception {
        TIImageTool.localize();
        ImageFormat.setSettings(new Settings(TIImageTool.getOperatingSystem()));
        String out = arg[0];
        int sizeMB = Integer.parseInt(arg[1]);
        String name = arg[2];
        int format = out.toLowerCase().endsWith(".chd") ? ImageFormat.CHD : ImageFormat.RAWHD;

        // partition parameters as NewIDEImageDialog.getParameters (one partition, the last one)
        double au = (sizeMB * 2) / 31.0;
        int auSize = au > 8 ? 16 : au > 4 ? 8 : au > 2 ? 4 : au > 1 ? 2 : 1;
        int res = sizeMB < 50 ? (2 << (sizeMB / 16 + 9)) : ((sizeMB - 50) * 2 / 3 + 128) * 64;
        if (res > 16320) res = 16320;
        if (res < 512) res = 512;
        FormatParameters param = new FormatParameters(name, true);
        param.setHD(Time.createNow(), auSize, res, HarddiskFileSystem.SCSI);
        param.setTotal(sizeMB * 4096 - 2);

        MemoryImageFormat mif = new MemoryImageFormat("idepart", 0, true);
        byte[] parttable = new byte[TFileSystem.SECTOR_LENGTH];
        Utilities.setString(parttable, 0, "*TI99FSPT*", 10);
        Utilities.setInt16(parttable, 0x0a, 0xffff);
        Utilities.setInt16(parttable, 0x0c, 0x0000);
        Utilities.setString(parttable, 0x0e, "PT", 2);
        Utilities.setInt32be(parttable, 0x10, 0x00000000);
        int sectors512 = sizeMB * 2048;
        Utilities.setInt32be(parttable, 0x14, sectors512);
        Utilities.setInt32be(parttable, 0x18, 1);
        Utilities.setInt32be(parttable, 0x1c, param.totalsectors / 2);
        Utilities.setInt16(parttable, 0xfe, 0x5aa5);
        mif.writeSector(new Sector(0, parttable));
        mif.writeSector(new Sector(1, new byte[TFileSystem.SECTOR_LENGTH]));

        IDEFileSystem fs = new IDEFileSystem(param);
        byte[] initsec = fs.createInitArray();
        for (int j = 0; j < initsec.length / TFileSystem.SECTOR_LENGTH; j++)
            mif.writeSector(new Sector(2 + j, initsec, j * TFileSystem.SECTOR_LENGTH));
        mif.nextGeneration(true);

        FormatParameters newparams = new FormatParameters("IDE", false);
        newparams.type = HarddiskFileSystem.IDE;
        newparams.totalsectors = 2 * sectors512;
        newparams.formatUnitSectors = 32;
        new File(out).delete();
        FileImageFormat img = (FileImageFormat) ImageFormat.getImageFormat(out, format, newparams);
        img.saveImageFromOld(mif);
        System.out.println("created " + out + ": " + sizeMB + " MiB IDE image, partition " + name
                           + ", AU " + auSize + " sectors, reserved " + res);
    }
}
