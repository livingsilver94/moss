/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * moss.client.metadb
 *
 * Metadata DB
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module moss.client.metadb;
import moss.core.errors;
import moss.client.installation : Mutability;
import moss.db.keyvalue;
import moss.db.keyvalue.errors;
import moss.db.keyvalue.interfaces;
import moss.db.keyvalue.orm;
import std.file : exists;
import std.experimental.logger;
import std.string : format;

public import std.stdint : uint64_t;
public import moss.deps.dependency;
import moss.deps.registry : ItemInfo;

/**
 * Simple ORM to store backlinks for providers.
 */
@Model struct ProviderMap
{
    /**
     * Something along the lines of, pkgconfig(someName)
     */
    @PrimaryKey string identifier;

    /**
     * Package identifiers matching in the map
     */
    string[] pkgIDs;
}

/**
 * A MetaEntry is our ORM-specific storage of moss
 * metadata.
 */
@Model public struct MetaEntry
{
    /**
     * Primary key in the db *is* the package ID
     */
    @PrimaryKey string pkgID;

    /**
     * Package name
     */
    string name;

    /**
     * Human readable version identifier
     */
    string versionIdentifier;

    /**
     * Package release as set in stone.yml
     */
    uint64_t sourceRelease;

    /**
     * Build machinery specific build release
     */
    uint64_t buildRelease;

    /**
     * Architecture this was built for
     */
    string architecture;

    /**
     * Brief one line summary of the package
     */
    string summary;

    /**
     * Description of the package
     */
    string description;

    /**
     * The source-grouping ID
     */
    string sourceID;

    /** 
     * Where'd we find this guy..
     */
    string homepage;

    /**
     * Licenses this is available under
     */
    string[] licenses;

    /**
     * All dependencies
     */
    Dependency[] dependencies;

    /**
     * All providers, including name()
     */
    Provider[] providers;

    /**
     * If relevant: uri to fetch from
     */
    string uri;

    /**
     * If relevant: hash for the download
     */
    string hash;

    /**
     * How big is this package in the repo..?
     */
    uint64_t downloadSize;
}

/**
 * Either works or it doesn't :)
 */
public alias MetaResult = Optional!(Success, Failure);

/**
 * Metadata encapsulation within a DB.
 *
 * Used for storing system wide (installed) packages as well
 * as powering "remotes".
 */
public final class MetaDB
{
    @disable this();

    /**
     * Construct a new MetaDB from the given path
     */
    this(string dbPath, Mutability mut) @safe
    {
        this.dbPath = dbPath;
        this.mut = mut;
    }

    /**
     * Grab ItemInfo for the given pkg, which saves a lot
     * of effort for the plugins.
     */
    auto info(string pkgID) @safe
    {
        MetaEntry entry;
        immutable err = db.view((in tx) => entry.load(tx, pkgID));
        if (!err.isNull)
        {
            return ItemInfo.init;
        }
        immutable licenses = () @trusted {
            return cast(immutable(string[])) entry.licenses;
        }();
        return ItemInfo(entry.name, entry.summary, entry.description,
                entry.sourceRelease, entry.versionIdentifier, entry.homepage, licenses);
    }

    auto list() @safe
    {
        MetaEntry[] entries;

        db.view((in tx) @safe {
            foreach (ent; tx.list!MetaEntry())
            {
                entries ~= ent;
            }
            return NoDatabaseError;
        });
        return entries;
    }

    /**
     * Connect to the underlying storage
     *
     * Returns: Success or Failure
     */
    MetaResult connect() @safe
    {
        tracef("MetaDB: %s", dbPath);
        auto flags = mut == Mutability.ReadWrite
            ? DatabaseFlags.CreateIfNotExists : DatabaseFlags.ReadOnly;

        /* We have no DB. */
        if (!dbPath.exists && mut == Mutability.ReadOnly)
        {
            return cast(MetaResult) fail(format!"MetaDB: Cannot find %s"(dbPath));
        }

        Database.open("lmdb://" ~ dbPath, flags).match!((Database db) {
            this.db = db;
        }, (DatabaseError err) { throw new Exception(err.message); });

        /**
         * Ensure our DB model exists.
         */
        if (mut == Mutability.ReadWrite)
        {
            auto err = db.update((scope tx) => tx.createModel!(MetaEntry, ProviderMap));
            if (!err.isNull)
            {
                return cast(MetaResult) fail(err.message);
            }
        }

        return cast(MetaResult) Success();
    }

    /**
     * Load from the remote index file
     */
    MetaResult loadFromIndex(string indexFile) @safe
    {
        import moss.format.binary.reader : Reader;
        import moss.format.binary.payload.meta : MetaPayload, RecordTag, RecordType;
        import std.stdio : File;

        scope Reader reader = new Reader(File(indexFile, "rb"));
        scope (exit)
        {
            reader.close();
        }

        immutable wipe = db.update((scope tx) @safe {
            auto e1 = tx.removeAll!MetaEntry;
            if (!e1.isNull)
            {
                return e1;
            }
            return tx.removeAll!ProviderMap;
        });
        if (!wipe.isNull)
        {
            return cast(MetaResult) fail(wipe.message);
        }
        immutable rebuild = db.update((scope tx) => tx.createModel!(MetaEntry, ProviderMap));
        if (!rebuild.isNull)
        {
            return cast(MetaResult) fail(rebuild.message);
        }

        /**
         * Store a single provider.
         */
        static DatabaseResult storeProvider(string pkgID, in Provider prov, scope Transaction tx) @safe
        {
            auto bucketID = prov.toString();
            ProviderMap storage;
            immutable e = storage.load(tx, bucketID);
            if (e.code != DatabaseErrorCode.BucketNotFound && e.code
                    != DatabaseErrorCode.KeyNotFound)
            {
                return e;
            }
            storage.pkgIDs ~= pkgID;
            immutable e2 = storage.save(tx);
            if (!e2.isNull)
            {
                return e2;
            }
            return NoDatabaseError;
        }

        static DatabaseResult helper(scope Reader reader, scope Transaction tx) @trusted
        {
            foreach (payload; reader.payloads!MetaPayload)
            {
                MetaPayload mp = cast(MetaPayload) payload;
                MetaEntry entry;
                entry.pkgID = mp.getPkgID;
                foreach (pair; mp)
                {
                    final switch (pair.tag)
                    {
                    case RecordTag.Architecture:
                        entry.architecture = pair.get!string;
                        break;
                    case RecordTag.BuildRelease:
                        entry.buildRelease = pair.get!uint64_t;
                        break;
                    case RecordTag.Conflicts:
                        /* Not yet supported */
                        break;
                    case RecordTag.Depends:
                        entry.dependencies ~= pair.get!Dependency;
                        break;
                    case RecordTag.Description:
                        entry.description = pair.get!string;
                        break;
                    case RecordTag.Homepage:
                        entry.homepage = pair.get!string;
                        break;
                    case RecordTag.License:
                        entry.licenses ~= pair.get!string;
                        break;
                    case RecordTag.Name:
                        entry.name = pair.get!string;
                        break;
                    case RecordTag.PackageHash:
                        entry.hash = pair.get!string;
                        break;
                    case RecordTag.PackageSize:
                        entry.downloadSize = pair.get!uint64_t;
                        break;
                    case RecordTag.PackageURI:
                        entry.uri = pair.get!string;
                        break;
                    case RecordTag.Provides:
                        entry.providers ~= pair.get!Provider;
                        break;
                    case RecordTag.Release:
                        entry.sourceRelease = pair.get!uint64_t;
                        break;
                    case RecordTag.SourceID:
                        entry.sourceID = pair.get!string;
                        break;
                    case RecordTag.Summary:
                        entry.summary = pair.get!string;
                        break;
                    case RecordTag.Unknown:
                        /* derp */
                        break;
                    case RecordTag.Version:
                        entry.versionIdentifier = pair.get!string;
                        break;
                    }
                }

                /* We need to store all the providers now.. */
                foreach (prov; entry.providers)
                {
                    auto e = storeProvider(entry.pkgID, prov, tx);
                    if (!e.isNull)
                    {
                        return e;
                    }
                }

                /* Now store the name() provider. */
                auto e = storeProvider(entry.pkgID, Provider(entry.name,
                        ProviderType.PackageName), tx);
                if (!e.isNull)
                {
                    return e;
                }

                immutable err = entry.save(tx);
                if (!err.isNull)
                {
                    return err;
                }
            }
            return NoDatabaseError;
        }

        immutable err = db.update((scope tx) @safe { return helper(reader, tx); });
        if (err.isNull)
        {
            return cast(MetaResult) Success();
        }
        return cast(MetaResult) fail(err.message);
    }

    /**
     * Close the underlying connection
     */
    void close() @safe
    {
        if (db !is null)
        {
            db.close();
            db = null;
        }
    }

private:

    string dbPath;
    Mutability mut;
    Database db;
}