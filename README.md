# ckSurf Mapchooser v1

## About
This is a edit of the default SourceMod mapchooser and nomination plugin, it provides functionality for any ckSurf based timer to display 

## Requirements

* Sourcemod 1.8
* MySQL (SQLite may work but is not supported by me)

## Installation

* Upload all the files to your csgo server directory
* Add a MySQL database called `mapchooser to `csgo/addons/sourcemod/configs/databases.cfg`
* Set `sm_cksurf_type` in your server.cfg (0 if using original/nikos/marcos ckSurf, 1 if using fluffys ckSurf)
* Set `sm_server_tier` in your server.cfg to the tier of maps you want appearing the nominate list. Example, for a tier 1-3 server, set it to `sm_server_tier 1.3`, a tier 1 only server would be `sm_server_tier 1.0`