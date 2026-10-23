// Copy whole directory trees between TI disk images and host folders with TIImageTool's classes
// (Michael Zapf, GPL-3), e.g. a MAME HFDC hard disk (CHD) into an IDE image made by MakeIDE:
//
//   java -cp <timt classes>:<jars> de.mizapf.timt.CopyTree SRC[#n] DST#n [DSTDIR]
//
// SRC is an image (read from its root) or a host folder of TIFILES files and subfolders (as written by
// "export"); with DSTDIR the tree goes into that subdirectory of DST's root (created if needed).
// Files keep their names, types and dates (TIFILES round trip); directories are created as needed,
// files that exist are replaced.
//
//   java ... de.mizapf.timt.CopyTree export SRC[#n] HOSTDIR
//
// writes the tree as TIFILES files (named after the TI file) and subfolders.
package de.mizapf.timt;

import java.io.*;
import java.lang.reflect.Method;
import java.nio.file.Files;
import de.mizapf.timt.files.*;
import de.mizapf.timt.util.*;

public class CopyTree {
    static int files = 0, dirs = 0, failed = 0;
    static Method open;
    static CommandShell com;

    public static void main(String[] arg) throws Exception {
        TIImageTool.localize();
        com = new CommandShell();
        open = CommandShell.class.getDeclaredMethod("openImage", String.class);
        open.setAccessible(true);
        if (arg[0].equals("export")) {
            exportTree(((Volume) open.invoke(com, arg[1])).getRootDirectory(), new File(arg[2]));
            System.out.println("exported " + files + " files, " + dirs + " directories");
            return;
        }
        Volume dst = (Volume) open.invoke(com, arg[1]);
        Directory to = dst.getRootDirectory();
        if (arg.length > 2) {
            to = to.hasSubdirectory(arg[2]) ? to.getSubdirectory(arg[2]) : to.createSubdirectory(arg[2]);
            dirs++;
        }
        File host = new File(arg[0]);
        if (host.isDirectory())
            importTree(host, to);
        else
            copy(((Volume) open.invoke(com, arg[0])).getRootDirectory(), to);
        to.commit(false);
        dst.getRootDirectory().commit(true);
        dst.saveImage();
        System.out.println("copied " + files + " files, " + dirs + " directories, " + failed + " failed");
    }

    static Directory subdir(Directory to, String name) throws Exception {
        if (to.hasSubdirectory(name)) return to.getSubdirectory(name);
        dirs++;
        return to.createSubdirectory(name);
    }

    static void put(Directory to, byte[] tif, String name, String where) {
        try {
            to.insertFile(tif, name, false, true);      // overwrite
            files++;
        } catch (Exception x) {
            System.err.println(where + ": " + x);
            failed++;
        }
    }

    static void copy(Directory from, Directory to) throws Exception {
        for (TFile f : from.getFiles())
            put(to, TIFiles.createFromFile(f).toByteArray(), f.getName(), from.getFullPathname() + "." + f.getName());
        for (Directory d : from.getDirectories()) {
            Directory nd = subdir(to, d.getName());
            copy(d, nd);
            nd.commit(false);
        }
        to.commit(false);
    }

    static void importTree(File from, Directory to) throws Exception {
        File[] list = from.listFiles();
        java.util.Arrays.sort(list);
        for (File f : list) {
            if (f.isDirectory()) {
                Directory nd = subdir(to, f.getName());
                importTree(f, nd);
                nd.commit(false);
            } else {
                byte[] tif = Files.readAllBytes(f.toPath());
                if (TIFiles.hasHeader(tif)) put(to, tif, TIFiles.getName(tif), f.getPath());
            }
        }
        to.commit(false);
    }

    static void exportTree(Directory from, File to) throws Exception {
        to.mkdirs();
        for (TFile f : from.getFiles()) {
            String n = f.getName().replace('/', '_').replace('\\', '_').replace('*', 'x');
            Files.write(new File(to, n).toPath(), TIFiles.createFromFile(f).toByteArray());
            files++;
        }
        for (Directory d : from.getDirectories()) {
            dirs++;
            exportTree(d, new File(to, d.getName()));
        }
    }
}
