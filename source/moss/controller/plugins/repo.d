/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * moss.controller.plugins.repo
 *
 * The repo plugin encapsulates access to online/remote moss index repositories.
 *
 * Thus, it provides the means to search for software and install dependencies.
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module moss.controller.plugins.repo;

public import moss.deps.registry;

import moss.storage.db.metadb;
import moss.format.binary.reader;
import moss.format.binary.payload.meta;
import std.algorithm : each, map;
import std.exception : enforce;
import std.array;
import std.file : mkdirRecurse, rmdirRecurse, exists;
import moss.context;
import moss.storage.cachepool;
import std.path : dirName;
import moss.core.fetchcontext;
import std.stdint : uint64_t;
import std.string : endsWith;

/**
 * The repo plugin encapsulates access to online software repositories providing
 * the means to search for software , and install a full chain of met dependencies.
 */
public final class RepoPlugin : RegistryPlugin
{

    @disable this();

    /**
     * Construct a new RepoPlugin with the given ID
     */
    this(CachePool pool, in string id, in string uri)
    {
        this._id = id;
        this._pool = pool;
        this._uri = uri;

        auto rootOrigin = join([context.paths.remotes, id], "/");
        dbPath = join([rootOrigin, "db"], "/");
        cachePath = join([rootOrigin, "cache"], "/");

        [rootOrigin, cachePath].each!((p) => p.mkdirRecurse());
        metaDB = new MetaDB(dbPath);
    }

    /**
     * Return the ID for this RepoPlugin
     */
    pragma(inline, true) pure @property string id() @safe @nogc nothrow const
    {
        return _id;
    }

    /**
     * Return the URI property of this RepoPlugin
     */
    pragma(inline, true) pure @property const(string) uri() @safe @nogc nothrow const
    {
        return _uri;
    }

    /**
     * Attempt to update this repo plugin
     */
    void update(FetchContext context)
    {
        auto localIndexPath = join([cachePath, "stone.index"], "/");
        auto fetchable = Fetchable(uri, localIndexPath, 0, FetchType.RegularFile, (f, l) {
            reloadIndex(localIndexPath);
        });
        context.enqueue(fetchable);
    }

    /**
     * Return any matching providers
     */
    override RegistryItem[] queryProviders(in ProviderType type, in string matcher,
            ItemFlags flags = ItemFlags.None)
    {
        /* Only return available items */
        if (flags != ItemFlags.None && (flags & ItemFlags.Available) != ItemFlags.Available)
        {
            return null;
        }

        return metaDB.byProvider(type, matcher).map!((i) => RegistryItem(i,
                this, ItemFlags.Available)).array();
    }

    /**
     * Provide details on a singular package
     */
    override NullableRegistryItem queryID(in string pkgID) const
    {
        if (metaDB.hasID(pkgID))
        {
            return NullableRegistryItem(RegistryItem(pkgID,
                    cast(RegistryPlugin) this, ItemFlags.Available));
        }
        return NullableRegistryItem();
    }

    /**
     * Return the dependencies for the given pkgID
     */
    override const(Dependency)[] dependencies(in string pkgID) const
    {
        return metaDB.dependencies(pkgID).array();
    }

    /**
     * Return the providers for the given pkgID
     */
    override const(Provider)[] providers(in string pkgID) const
    {
        return metaDB.providers(pkgID).array();
    }

    /**
     * Return  info for the package
     */
    override ItemInfo info(in string pkgID) const
    {
        if (metaDB.hasID(pkgID))
        {
            return metaDB.info(pkgID);
        }
        return ItemInfo();
    }

    /**
     * List all known pkgIDs within the MetaDB
     */
    override const(RegistryItem)[] list(in ItemFlags flags) const
    {
        /* Only list available items */
        if (flags != ItemFlags.None && (flags & ItemFlags.Available) != ItemFlags.Available)
        {
            return null;
        }

        return metaDB.list().map!((p) => RegistryItem(p, cast(RepoPlugin) this,
                ItemFlags.Available)).array();
    }

    /**
     * Free up assets we have, i.e. the DB
     */
    override void close()
    {
        if (metaDB is null)
        {
            return;
        }
        metaDB.close();
        metaDB.destroy();
        metaDB = null;
    }

    /**
     * Return the final cache path
     */
    string finalCachePath(in string pkgID)
    {
        const auto hashsum = metaDB.getValue!string(pkgID, RecordTag.PackageHash);
        return _pool.finalPath(hashsum);
    }

    /**
     * No-op
     */
    override void fetchItem(FetchContext context, in string pkgID)
    {
        const auto pkgURI = join([
            uri.dirName, metaDB.getValue!string(pkgID, RecordTag.PackageURI)
        ], "/");
        const auto hashsum = metaDB.getValue!string(pkgID, RecordTag.PackageHash);
        const auto expectedSize = metaDB.getValue!uint64_t(pkgID, RecordTag.PackageSize);

        enforce(pkgURI.endsWith(".stone") && !hashsum.empty && expectedSize > 0);
        auto dest = _pool.stagingPath(hashsum);
        dest.dirName.mkdirRecurse();
        auto fetchable = Fetchable(pkgURI, dest, expectedSize, FetchType.RegularFile, null);
        context.enqueue(fetchable);
    }

private:

    /**
     * Reload the index into the DB
     */
    void reloadIndex(in string indexLocal)
    {
        /* Wipe old DB */
        close();
        if (dbPath.exists)
        {
            dbPath.rmdirRecurse();
        }
        metaDB = new MetaDB(dbPath);

        auto fi = File(indexLocal, "rb");
        auto rdr = new Reader(fi);
        scope (exit)
        {
            rdr.close();
        }

        /* Make sure this is actually a repo */
        enforce(rdr.archiveHeader.type == MossFileType.Repository, "Unsupported repository index");

        /* Insert every payload in */
        foreach (hdr; rdr.headers)
        {
            if (hdr.type != PayloadType.Meta)
            {
                continue;
            }
            auto meta = cast(MetaPayload) hdr.payload;
            metaDB.install(meta);
        }
    }

    MetaDB metaDB = null;
    string _id = null;
    string _uri = null;
    string cachePath = null;
    string dbPath = null;
    CachePool _pool = null;
}
