@inventory-api/ is meant to be all the interfaces (and probably all the generated code) for @inventory-impl/ @inventory-server/ and @inventory-webapp/ 

> **Naming note (2026-08-07):** the module originally called `inventory-webapp` was
> renamed to `inventory-web-api` — GitHub repo, directory, and Maven artifact all
> renamed. Mentions of "inventory-webapp" below (its API component, token auth, Google
> frontend, admin section) describe what is now `inventory-web-api`. A **new**
> `inventory-webapp` module has been created to receive the web UI, which is being
> extracted out of `inventory-web-api` (see PLAN.md, Phase 5), leaving
> `inventory-web-api` as the pure browser-facing API tier.

This is a fairly complicated inventory system 
It needs to handle both physical objects as well as data.
Data can come in the form of physical media or remote/network/cloud storage.
Data can be immutable (write-once disks like CDs) or mutable (like a disk).
Data can be an archive which acts like a "sub-container" for data on whatever media it is present on

Containers have locations (Denoted by name and by lat/long)
Any item can effectively be called a container by virtue of putting things into it.


This is a java application built with maven using its parent `inventory-parent`, which since 2026-08-18 lives OUTSIDE this workspace at `../inventory-parent` (its own repo, no longer a submodule) and parents off `io.artifexlabs:artifex-maven-parent`. Building this workspace therefore requires both of those installed or published — see [MAVEN_RELEASES.md](MAVEN_RELEASES.md). The apis need to be publishable as a backend so that other languages can use them,

Any given object must have a unique id that can be used to create a fairly small QR code that will identifiy a specific item in the inventory-webapp's API compontnt.

@inventory-webapp should have an API part that is a well-known format like swagger, etc, and a UI part that display things from the API part.
The api should require a token to use and the webapp should have google auth as its frontend.  It needs an admin section for adding users and the entire thing needs an audit trail that shows all the changes it makes.  These can be created in @inventory-api as interfaces.

It should be possible to perform CRUD operations on inventory, attach assets like pictures and audio, and add descriptions.  Optional aspects of physical items would be par values (min on-hand, max on-hand, current on-hand) with possibly different locations for various instances of an item


All of this should be usable by an ios app and eventually an android app that could take the pictures and record descriptions that are attached to items.

The api should also allow for connecting to label printers to generate QR-coded labels for application that would allow scanning from the qr code directly to the ios/android app or to the webapp


# Build and Deploy

The entire application should be built as a set of components that are eventually collected as a set of dependencies for a graalvm native Quarkus application/executable running  as a container

It is essential to keep day-2 problems in mind when working with this codebase.

Storage should be done as easily as possible but still using some relational database or equivalent.  All database work must have liquibase changesets to apply, so that data may migrate forward (and possibly backwards) for releases 

The application is expected to be a series of vertx verticles that are deployed as a group of containers, such as with docker swarm, nomad, or even kubernetes.
Each container would be 1 or more verticles that communicates across the networked event bus for interacting with other verticles.  While microservices should be delimited to one-per-container, there are some places where this might be inconventient or cause trouble moving forward with changes (see day-2 problems above)

All data must be stored or changed in a transactioanlly complete way.  The system should be capable of going down and restarting from cold or warm without issue.



