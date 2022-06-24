/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * moss.cli.inspect_command
 *
 * The inspect command is used to inspect the payload of a .stone package.
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module moss.cli.inspect_command;

public import moss.core.cli;
import moss.core;
import moss.deps.dependency;
import moss.format.binary.reader;
import moss.format.binary.payload;
import std.stdio;

/**
 * InspectCommand is used to inspect the payload of an archive
 */
@CommandName("inspect")
@CommandHelp("Inspect contents of a .stone file",
        "With a locally available .stone file, this command will attempt to
read, validate and extract information on the given package.
If the file is not a valid .stone file for moss, an error will be
reported.")
@CommandUsage("[.stone file]")
public struct InspectCommand
{
    /** Extend BaseCommand with Inspect utility */
    BaseCommand pt;
    alias pt this;

    /**
     * Main entry point into the InspectCommand utility
    */
    @CommandEntry() int run(ref string[] argv)
    {
        import std.algorithm : each;

        if (argv.length < 1)
        {
            stderr.writeln("Requires an argument");
            return ExitStatus.Failure;
        }

        argv.each!((a) => readPackage(a));
        return ExitStatus.Success;
    }

    /**
     * Helper to read each package
     */
    void readPackage(string packageName)
    {
        import std.file : exists;
        import std.conv : to;

        if (!packageName.exists())
        {
            stderr.writeln("No such package: ", packageName);
            return;
        }

        auto reader = new Reader(File(packageName, "rb"));

        writeln("Archive: ", packageName);

        /**
         * Emit all headers
         */
        foreach (hdr; reader.headers)
        {
            /* Calculate compression savings */
            immutable float comp = hdr.storedSize;
            immutable float uncomp = hdr.plainSize;
            auto puncomp = formatBytes(uncomp);
            auto savings = (comp > 0 ? (100.0f - (comp / uncomp) * 100.0f) : 0);
            writefln("Payload: %s [Records: %d Compression: %s, Savings: %.2f%%, Size: %s]",
                    to!string(hdr.type), hdr.numRecords,
                    to!string(hdr.compression), savings, puncomp);
            switch (hdr.type)
            {
            case PayloadType.Meta:
                printMeta(hdr.payload);
                break;
            case PayloadType.Layout:
                printLayout(hdr.payload);
                break;
            case PayloadType.Index:
                printIndex(hdr.payload);
                break;
            default:
                break;
            }
        }
    }

    /**
     * Print all metadata in a local package file
     */
    void printMeta(scope Payload p)
    {
        import moss.format.binary.payload.meta : MetaPayload, RecordTag, RecordType;
        import std.conv : to;

        auto metadata = cast(MetaPayload) p;
        foreach (pair; metadata)
        {
            writef("%-15s : ", pair.tag.to!string);

            /* TODO: Care more about otheru values :)) */
            switch (pair.type)
            {
            case RecordType.Int8:
                writeln(pair.get!int8_t);
                break;
            case RecordType.Uint64:
                if (pair.tag == RecordTag.PackageSize)
                {
                    writeln(formatBytes(pair.get!uint64_t));
                }
                else
                {
                    writeln(pair.get!uint64_t);
                }
                break;
            case RecordType.String:
                writeln(pair.get!string);
                break;
            case RecordType.Dependency:
                writeln(pair.get!Dependency);
                break;
            case RecordType.Provider:
                writeln(pair.get!Provider);
                break;
            default:
                writeln("Unsupported value type: ", pair.type);
                break;
            }
        }
        writeln();
    }

    /**
     * Print all layout information in a local package file
     */
    void printLayout(scope Payload p)
    {
        /* Grab layout */
        import moss.format.binary.payload.layout : LayoutPayload;

        auto layout = cast(LayoutPayload) p;
        import std.conv : to;

        foreach (entry; layout)
        {
            switch (entry.entry.type)
            {
            case FileType.Regular:
                writefln("  - /usr/%s -> %s [%s]",
                        entry.target, entry.digestString(), to!string(entry.entry.type));
                break;
            case FileType.Symlink:
                writefln("  - /usr/%s -> %s [%s]",
                        entry.target, entry.symlinkSource(), to!string(entry.entry.type));
                break;
            default:
                writefln("  - /usr/%s [%s]", entry.target, to!string(entry.entry.type));
                break;

            }
        }
    }

    /**
     * Print all index entries within the payload
     */
    void printIndex(scope Payload p)
    {
        import moss.format.binary.payload.index : IndexPayload;

        auto index = cast(IndexPayload) p;
        foreach (entry; index)
        {
            writefln("  - %s [size: %9s]", cast(string) entry.digestString(),
                    formatBytes(entry.contentSize));
        }
    }

    /**
     * Convert bytes to a pretty condensed version
     */
    string formatBytes(float bytes)
    {
        import std.format : format;

        const string[4] units = ["B ", "KB", "MB", "GB"];
        const int[4] deci = [0, 2, 2, 2];
        const auto k = 1000;

        for (int i = 3; i >= 0; i--)
        {
            auto correctsize = bytes / (k ^^ i);
            if (correctsize > 1)
            {
                return "%.*f %s".format(deci[i], correctsize, units[i]);
            }
        }
        assert(0);
    }
}
