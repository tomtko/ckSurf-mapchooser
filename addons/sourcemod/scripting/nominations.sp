/**
 * vim: set ts=4 :
 * =============================================================================
 * SourceMod Rock The Vote Plugin
 * Creates a map vote when the required number of players have requested one.
 *
 * SourceMod (C)2004-2014 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#include <mapchooser>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "Map Nominations",
	author = "AlliedModders LLC",
	description = "Provides Map Nominations",
	version = SOURCEMOD_VERSION,
	url = "http://www.sourcemod.net/"
};

ConVar g_Cvar_ExcludeOld;
ConVar g_Cvar_ExcludeCurrent;
ConVar g_Cvar_ServerTier;
ConVar g_Cvar_TimerType;
ConVar g_Cvar_IncludeAllMaps;
ConVar g_Cvar_DatabaseName;

Menu g_MapMenu = null;
ArrayList g_MapList = null;
ArrayList g_GlobalMapList = null;
int g_mapFileSerial = -1;

#define MAPSTATUS_ENABLED (1<<0)
#define MAPSTATUS_DISABLED (1<<1)
#define MAPSTATUS_EXCLUDE_CURRENT (1<<2)
#define MAPSTATUS_EXCLUDE_PREVIOUS (1<<3)
#define MAPSTATUS_EXCLUDE_NOMINATED (1<<4)

StringMap g_mapTrie = null;

// SQL
Handle g_hDb = null;
#define PERCENT 0x25

int g_iMenuLevel[MAXPLAYERS + 1];

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("nominations.phrases");

	db_setupDatabase();

	int arraySize = ByteCountToCells(PLATFORM_MAX_PATH);
	g_MapList = new ArrayList(arraySize);
	g_GlobalMapList = new ArrayList(arraySize);
	g_Cvar_ExcludeOld = CreateConVar("sm_nominate_excludeold", "1", "Specifies if the current map should be excluded from the Nominations list", 0, true, 0.00, true, 1.0);
	g_Cvar_ExcludeCurrent = CreateConVar("sm_nominate_excludecurrent", "1", "Specifies if the MapChooser excluded maps should also be excluded from Nominations", 0, true, 0.00, true, 1.0);
	g_Cvar_ServerTier = CreateConVar("sm_server_tier", "1.0", "Specifies the servers tier to only include maps from, for example if you want a tier 1-3 server make it 1.3, a tier 2 only server would be 2.0, etc", 0, true, 1.0, true, 6.0);
	g_Cvar_TimerType = CreateConVar("sm_cksurf_type", "1", "Specifies the type of ckSurf the server is using, 0 for normal/niko/marcos, 1 for fluffys");
	g_Cvar_IncludeAllMaps = CreateConVar("sm_include_all", "0", "Include all maps in nominate, even if the map isnt found inside the mapycycle.txt/multi_server_mapcycle.txt", 0, true, 0.00, true, 1.0);
	g_Cvar_DatabaseName = CreateConVar("sm_mapchooser_db_name", "surftimer", "Specifies the database name that will be used in databases.cfg");

	RegConsoleCmd("sm_nominate", Command_Nominate);
	
	RegAdminCmd("sm_nominate_addmap", Command_Addmap, ADMFLAG_CHANGEMAP, "sm_nominate_addmap <mapname> - Forces a map to be on the next mapvote.");
	AutoExecConfig(true, "cksurf_nominations");
	g_mapTrie = new StringMap();
}

public void OnConfigsExecuted()
{
	SetMapListCompatBind("cksurf", "mapcyclefile");
	
	Handle multiserver = FindConVar("ck_multi_server_mapcycle");
	if (GetConVarBool(multiserver))
		SetMapListCompatBind("cksurf", "addons/sourcemod/configs/ckSurf/multi_server_mapcycle.txt");
	else
		SetConVarBool(g_Cvar_IncludeAllMaps, true);

	if (ReadMapList(g_GlobalMapList, g_mapFileSerial, "cksurf", MAPLIST_FLAG_CLEARARRAY) == null)
	{
		if (g_mapFileSerial == -1)
		{
			SetConVarBool(g_Cvar_IncludeAllMaps, true);
			LogError("Unable to create a valid map list.");
		}
	}

	if (g_GlobalMapList != null)
	{
		for (int i = 0; i < g_GlobalMapList.Length; i++)
		{
			char sCurrentMap[256];
			g_GlobalMapList.GetString(i, sCurrentMap, sizeof(sCurrentMap));
		}
	}

	SelectMapList();
	//BuildMapMenu();
}

public void OnNominationRemoved(const char[] map, int owner)
{
	int status;

	char resolvedMap[PLATFORM_MAX_PATH];
	FindMap(map, resolvedMap, sizeof(resolvedMap));

	/* Is the map in our list? */
	if (!g_mapTrie.GetValue(resolvedMap, status))
	{
		return;
	}

	/* Was the map disabled due to being nominated */
	if ((status & MAPSTATUS_EXCLUDE_NOMINATED) != MAPSTATUS_EXCLUDE_NOMINATED)
	{
		return;
	}

	g_mapTrie.SetValue(resolvedMap, MAPSTATUS_ENABLED);
}

public Action Command_Addmap(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_nominate_addmap <mapname>");
		return Plugin_Handled;
	}

	char mapname[PLATFORM_MAX_PATH];
	char resolvedMap[PLATFORM_MAX_PATH];
	GetCmdArg(1, mapname, sizeof(mapname));

	if (FindMap(mapname, resolvedMap, sizeof(resolvedMap)) == FindMap_NotFound)
	{
		// We couldn't resolve the map entry to a filename, so...
		ReplyToCommand(client, "%t", "Map was not found", mapname);
		return Plugin_Handled;
	}

	char displayName[PLATFORM_MAX_PATH];
	GetMapDisplayName(resolvedMap, displayName, sizeof(displayName));

	int status;
	if (!g_mapTrie.GetValue(resolvedMap, status))
	{
		ReplyToCommand(client, "%t", "Map was not found", displayName);
		return Plugin_Handled;
	}

	NominateResult result = NominateMap(resolvedMap, true, 0);

	if (result > Nominate_Replaced)
	{
		/* We assume already in vote is the casue because the maplist does a Map Validity check and we forced, so it can't be full */
		ReplyToCommand(client, "%t", "Map Already In Vote", displayName);

		return Plugin_Handled;
	}


	g_mapTrie.SetValue(resolvedMap, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);


	ReplyToCommand(client, "%t", "Map Inserted", displayName);
	LogAction(client, -1, "\"%L\" inserted map \"%s\".", client, mapname);

	return Plugin_Handled;
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if (!client)
	{
		return;
	}

	if (strcmp(sArgs, "nominate", false) == 0)
	{
		ReplySource old = SetCmdReplySource(SM_REPLY_TO_CHAT);

		AttemptNominate(client);

		SetCmdReplySource(old);
	}
}

public Action Command_Nominate(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}

	if (args == 0)
	{
		AttemptNominate(client);
		return Plugin_Handled;
	}

	char mapname[PLATFORM_MAX_PATH];
	GetCmdArg(1, mapname, sizeof(mapname));

	if (FindMap(mapname, mapname, sizeof(mapname)) == FindMap_NotFound)
	{
		// We couldn't resolve the map entry to a filename, so...
		ReplyToCommand(client, "%t", "Map was not found", mapname);
		PrintToChat(client, "1");
		return Plugin_Handled;
	}

	char displayName[PLATFORM_MAX_PATH];
	GetMapDisplayName(mapname, displayName, sizeof(displayName));

	int status;
	if (!g_mapTrie.GetValue(mapname, status))
	{
		ReplyToCommand(client, "%t", "Map was not found", displayName);
		return Plugin_Handled;
	}
	

	if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
	{
		if ((status & MAPSTATUS_EXCLUDE_CURRENT) == MAPSTATUS_EXCLUDE_CURRENT)
		{
			ReplyToCommand(client, "[SM] %t", "Can't Nominate Current Map");
		}

		if ((status & MAPSTATUS_EXCLUDE_PREVIOUS) == MAPSTATUS_EXCLUDE_PREVIOUS)
		{
			ReplyToCommand(client, "[SM] %t", "Map in Exclude List");
		}

		if ((status & MAPSTATUS_EXCLUDE_NOMINATED) == MAPSTATUS_EXCLUDE_NOMINATED)
		{
			ReplyToCommand(client, "[SM] %t", "Map Already Nominated");
		}

		return Plugin_Handled;
	}

	NominateResult result = NominateMap(mapname, false, client);

	if (result > Nominate_Replaced)
	{
		if (result == Nominate_AlreadyInVote)
		{
			ReplyToCommand(client, "%t", "Map Already In Vote", displayName);
		}
		else
		{
			ReplyToCommand(client, "[SM] %t", "Map Already Nominated");
		}

		return Plugin_Handled;
	}

	/* Map was nominated! - Disable the menu item and update the trie */

	g_mapTrie.SetValue(mapname, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	PrintToChatAll("[SM] %t", "Map Nominated", name, displayName);

	return Plugin_Continue;
}

public void AttemptNominate(int client)
{
	Menu menu = CreateMenu(NominateTypeHandler);
	SetMenuTitle(menu, "Nominate Type:\n\n");
	AddMenuItem(menu, "0", "All Maps");
	AddMenuItem(menu, "1", "Maps By Tier");
	AddMenuItem(menu, "2", "Completed Maps");
	AddMenuItem(menu, "3", "Incomplete Maps");
	SetMenuOptionFlags(menu, MENUFLAG_BUTTON_EXIT);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);

	g_iMenuLevel[client] = 0;
}

public int NominateTypeHandler(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		switch (param2)
		{
			case 0:
			{
				g_iMenuLevel[param1] = 1;
				g_MapMenu.SetTitle("%T", "Nominate Title", param1);
				SetMenuExitBackButton(g_MapMenu, true);
				g_MapMenu.Display(param1, MENU_TIME_FOREVER);
			}
			case 1:
			{
				g_iMenuLevel[param1] = 1;
				DisplayTiersMenu(param1);
			}
			case 2:
			{
				g_iMenuLevel[param1] = 1;
				SelectCompletedMaps(param1);
			}
			case 3:
			{
				g_iMenuLevel[param1] = 1;
				SelectIncompleteMaps(param1);
			}
		}
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}

	return 0;
}

public void DisplayTiersMenu(int client)
{
	char szTier[16];
	char szBuffer[2][32];
	GetConVarString(g_Cvar_ServerTier, szTier, sizeof(szTier));
	ExplodeString(szTier, ".", szBuffer, 2, 32);
	//ReplaceString(szBuffer[1], 32, "0", "", false);
	int tier1 = StringToInt(szBuffer[0]);
	int tier2;

	if (StrEqual(szBuffer[1], "0"))
		tier2 = StringToInt(szBuffer[0]);
	else
		tier2 = StringToInt(szBuffer[1]);

	char szValue[32];
	char szTier2[2];
	Menu menu2 = CreateMenu(TierSelectHandler);
	SetMenuTitle(menu2, "Select a tier:\n\n");
	for (int i = tier1; i <= tier2; i++)
	{
		Format(szValue, sizeof(szValue), "Tier %i", i);
		IntToString(i, szTier2, sizeof(szTier2));
		AddMenuItem(menu2, szTier2, szValue);
	}
	SetMenuExitBackButton(menu2, true);
	DisplayMenu(menu2, client, MENU_TIME_FOREVER);
}

public int TierSelectHandler(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char szInfo[32];
		GetMenuItem(menu, param2, szInfo, 32);
		g_iMenuLevel[param1] = 2;
		SelectMapListTier(param1, szInfo);
	}
	else if (action == MenuAction_Cancel)
	{
		AttemptNominate(param1);
	}
	else if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
}

void BuildMapMenu()
{
	delete g_MapMenu;

	g_mapTrie.Clear();

	g_MapMenu = new Menu(Handler_MapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);

	char map[PLATFORM_MAX_PATH];

	ArrayList excludeMaps;
	char currentMap[PLATFORM_MAX_PATH];

	char szBuffer[2][256];

	if (g_Cvar_ExcludeOld.BoolValue)
	{
		excludeMaps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
		GetExcludeMapList(excludeMaps);
	}

	if (g_Cvar_ExcludeCurrent.BoolValue)
	{
		GetCurrentMap(currentMap, sizeof(currentMap));
	}

	for (int i = 0; i < g_MapList.Length; i++)
	{
		int status = MAPSTATUS_ENABLED;

		g_MapList.GetString(i, map, sizeof(map));

		FindMap(map, map, sizeof(map));

		ExplodeString(map, " - Tier", szBuffer, 2, 256);

		char displayName[PLATFORM_MAX_PATH];
		GetMapDisplayName(map, displayName, sizeof(displayName));

		if (g_Cvar_ExcludeCurrent.BoolValue)
		{
			if (StrEqual(map, currentMap) || StrEqual(szBuffer[0], currentMap))
			{
				status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_CURRENT;
			}
		}

		/* Dont bother with this check if the current map check passed */
		if (g_Cvar_ExcludeOld.BoolValue && status == MAPSTATUS_ENABLED)
		{
			if (excludeMaps.FindString(map) != -1 || excludeMaps.FindString(szBuffer[0]) != -1)
			{
				status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_PREVIOUS;
			}
		}

		g_MapMenu.AddItem(map, displayName);
		g_mapTrie.SetValue(map, status);
	}

	g_MapMenu.ExitButton = true;

	delete excludeMaps;
}

public int Handler_MapSelectMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char map[PLATFORM_MAX_PATH], name[MAX_NAME_LENGTH], displayName[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map), _, displayName, sizeof(displayName));

			GetClientName(param1, name, sizeof(name));

			NominateResult result = NominateMap(map, false, param1);

			/* Don't need to check for InvalidMap because the menu did that already */
			if (result == Nominate_AlreadyInVote)
			{
				PrintToChat(param1, "[SM] %t", "Map Already Nominated");
				return 0;
			}
			else if (result == Nominate_VoteFull)
			{
				PrintToChat(param1, "[SM] %t", "Max Nominations");
				return 0;
			}

			g_mapTrie.SetValue(map, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);

			if (StrContains(displayName, "»") != -1)
			{
				char szBuffer[2][256];
				ExplodeString(displayName, "» ", szBuffer, 2, 256);

				if (result == Nominate_Replaced)
				{
					PrintToChatAll("[SM] %t", "Map Nomination Changed", name, szBuffer[1]);
					return 0;
				}

				PrintToChatAll("[SM] %t", "Map Nominated", name, szBuffer[1]);
				return 0;
			}

			if (result == Nominate_Replaced)
			{
				PrintToChatAll("[SM] %t", "Map Nomination Changed", name, displayName);
				return 0;
			}

			PrintToChatAll("[SM] %t", "Map Nominated", name, displayName);
		}

		case MenuAction_DrawItem:
		{
			char map[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map));

			int status;

			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return ITEMDRAW_DEFAULT;
			}

			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				return ITEMDRAW_DISABLED;
			}

			return ITEMDRAW_DEFAULT;

		}

		case MenuAction_DisplayItem:
		{
			char map[PLATFORM_MAX_PATH], displayName[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map), _, displayName, sizeof(displayName));

			int status;

			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return 0;
			}

			char display[PLATFORM_MAX_PATH + 64];

			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				if ((status & MAPSTATUS_EXCLUDE_CURRENT) == MAPSTATUS_EXCLUDE_CURRENT)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Current Map", param1);
					return RedrawMenuItem(display);
				}

				if ((status & MAPSTATUS_EXCLUDE_PREVIOUS) == MAPSTATUS_EXCLUDE_PREVIOUS)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Recently Played", param1);
					return RedrawMenuItem(display);
				}

				if ((status & MAPSTATUS_EXCLUDE_NOMINATED) == MAPSTATUS_EXCLUDE_NOMINATED)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Nominated", param1);
					return RedrawMenuItem(display);
				}
			}

			return 0;
		}

		case MenuAction_Cancel:
		{
			if (g_iMenuLevel[param1] == 2)
				DisplayTiersMenu(param1);
			else
				AttemptNominate(param1);
			return 0;
		}
	}

	return 0;
}

public int Handler_ClientMapSelectMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char map[PLATFORM_MAX_PATH], name[MAX_NAME_LENGTH], displayName[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map), _, displayName, sizeof(displayName));

			GetClientName(param1, name, sizeof(name));

			NominateResult result = NominateMap(map, false, param1);

			/* Don't need to check for InvalidMap because the menu did that already */
			if (result == Nominate_AlreadyInVote)
			{
				PrintToChat(param1, "[SM] %t", "Map Already Nominated");
				return 0;
			}
			else if (result == Nominate_VoteFull)
			{
				PrintToChat(param1, "[SM] %t", "Max Nominations");
				return 0;
			}

			g_mapTrie.SetValue(map, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);

			if (result == Nominate_Replaced)
			{
				PrintToChatAll("[SM] %t", "Map Nomination Changed", name, displayName);
				return 0;
			}

			PrintToChatAll("[SM] %t", "Map Nominated", name, displayName);
		}

		case MenuAction_DrawItem:
		{
			char map[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map));

			int status;

			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return ITEMDRAW_DEFAULT;
			}

			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				return ITEMDRAW_DISABLED;
			}

			return ITEMDRAW_DEFAULT;

		}

		case MenuAction_DisplayItem:
		{
			char map[PLATFORM_MAX_PATH], displayName[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map), _, displayName, sizeof(displayName));

			int status;

			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return 0;
			}

			char display[PLATFORM_MAX_PATH + 64];

			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				if ((status & MAPSTATUS_EXCLUDE_CURRENT) == MAPSTATUS_EXCLUDE_CURRENT)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Current Map", param1);
					return RedrawMenuItem(display);
				}

				if ((status & MAPSTATUS_EXCLUDE_PREVIOUS) == MAPSTATUS_EXCLUDE_PREVIOUS)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Recently Played", param1);
					return RedrawMenuItem(display);
				}

				if ((status & MAPSTATUS_EXCLUDE_NOMINATED) == MAPSTATUS_EXCLUDE_NOMINATED)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Nominated", param1);
					return RedrawMenuItem(display);
				}
			}

			return 0;
		}

		case MenuAction_Cancel:
		{
			AttemptNominate(param1);
			return 0;
		}
	}

	return 0;
}

public void db_setupDatabase()
{
	char szError[255];
	char szDBName[32];
	GetConVarString(g_Cvar_DatabaseName, szDBName, sizeof(szDBName));
	g_hDb = SQL_Connect(szDBName, false, szError, 255);

	if (g_hDb == null)
	{
		SetFailState("[Nominations] Unable to connect to database (%s)", szError);
		return;
	}

	return;
}

public void SelectMapListTier(int client, char szTier[32])
{
	char szQuery[256];

	Format(szQuery, 256, "SELECT mapname, tier FROM ck_maptier WHERE mapname LIKE '%csurf%c' ANd tier = %s;", PERCENT, PERCENT, szTier);

	SQL_TQuery(g_hDb, SelectMapListTierCallback, szQuery, client, DBPrio_Low);
}

public void SelectMapListTierCallback(Handle owner, Handle hndl, const  char[] error, any client)
{
	if (hndl == null)
	{
		LogError("[Nominations] SQL Error (SelectMapListTierCallback): %s", error);
		return;
	}

	if (SQL_HasResultSet(hndl))
	{
		Menu menu = CreateMenu(Handler_MapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);

		char szMapName[PLATFORM_MAX_PATH];

		ArrayList excludeMaps;
		char currentMap[PLATFORM_MAX_PATH];

		if (g_Cvar_ExcludeOld.BoolValue)
		{
			excludeMaps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
			GetExcludeMapList(excludeMaps);
		}

		if (g_Cvar_ExcludeCurrent.BoolValue)
		{
			GetCurrentMap(currentMap, sizeof(currentMap));
		}

		int tier;
		char szValue[256];
		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, szMapName, 128);
			tier = SQL_FetchInt(hndl, 1);
			if (!GetConVarBool(g_Cvar_IncludeAllMaps) && bIsMapGlobal(szMapName) || GetConVarBool(g_Cvar_IncludeAllMaps))
			{
				Format(szValue, 256, "%s - Tier %i", szMapName, tier);

				int status = MAPSTATUS_ENABLED;
	
				FindMap(szMapName, szMapName, sizeof(szMapName));
	
				char displayName[PLATFORM_MAX_PATH];
				GetMapDisplayName(szMapName, displayName, sizeof(displayName));
				
				if (g_Cvar_ExcludeCurrent.BoolValue)
				{
					if (StrEqual(szMapName, currentMap))
					{
						status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_CURRENT;
					}
				}
	
				/* Dont bother with this check if the current map check passed */
				if (g_Cvar_ExcludeOld.BoolValue && status == MAPSTATUS_ENABLED)
				{
					if (excludeMaps.FindString(szMapName) != -1 || excludeMaps.FindString(szValue) != -1)
					{
						status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_PREVIOUS;
					}
				}
				
	
				AddMenuItem(menu, szValue, szMapName);
				g_mapTrie.SetValue(szMapName, status);
			}
		}

		char szTitle[64];
		Format(szTitle, 64, "Nominate Map - Tier %i", tier);
		SetMenuTitle(menu, szTitle);
		SetMenuExitBackButton(menu, true);
		DisplayMenu(menu, client, MENU_TIME_FOREVER);

		delete excludeMaps;
	}
}

public void SelectCompletedMaps(int client)
{
	char szQuery[1024];
	char szSteamId[32];

	GetClientAuthId(client, AuthId_Steam2, szSteamId, MAX_NAME_LENGTH, true);

	char szTier[16];
	char szBuffer[2][32];
	GetConVarString(g_Cvar_ServerTier, szTier, sizeof(szTier));
	ExplodeString(szTier, ".", szBuffer, 2, 32);

	if (GetConVarInt(g_Cvar_TimerType) == 1)
	{
		if (StrEqual(szBuffer[1], "0"))
		{
			Format(szQuery, 1024, "SELECT db1.name, db2.steamid, db2.mapname, db2.runtimepro as overall, db1.steamid, db3.tier, (SELECT COUNT(runtimepro) FROM ck_playertimes WHERE runtimepro <= (SELECT runtimepro FROM ck_playertimes WHERE steamid = '%s' AND mapname = db2.mapname AND style = 0 AND runtimepro > -1.0 ORDER BY runtimepro) AND mapname = db2.mapname AND style = 0 AND runtimepro > -1.0) AS rank, (SELECT count(1) FROM ck_playertimes WHERE mapname = db2.mapname AND style = 0) AS total FROM ck_playertimes as db2 INNER JOIN ck_playerrank as db1 on db2.steamid = db1.steamid INNER JOIN ck_maptier AS db3 ON db2.mapname = db3.mapname WHERE db2.steamid = '%s' AND db2.style = 0 AND db3.tier = %s AND db2.runtimepro > -1.0 ORDER BY mapname ASC;", szSteamId, szSteamId, szBuffer[0]);
		}
		else if (strlen(szBuffer[1]) > 0)
		{
			Format(szQuery, 1024, "SELECT db1.name, db2.steamid, db2.mapname, db2.runtimepro as overall, db1.steamid, db3.tier, (SELECT COUNT(runtimepro) FROM ck_playertimes WHERE runtimepro <= (SELECT runtimepro FROM ck_playertimes WHERE steamid = '%s' AND mapname = db2.mapname AND style = 0 AND runtimepro > -1.0 ORDER BY runtimepro) AND mapname = db2.mapname AND style = 0 AND runtimepro > -1.0) AS rank, (SELECT count(1) FROM ck_playertimes WHERE mapname = db2.mapname AND style = 0) AS total FROM ck_playertimes as db2 INNER JOIN ck_playerrank as db1 on db2.steamid = db1.steamid INNER JOIN ck_maptier AS db3 ON db2.mapname = db3.mapname WHERE db2.steamid = '%s' AND db2.style = 0 AND db3.tier >= %s AND db3.tier <= %s AND db2.runtimepro > -1.0 ORDER BY mapname ASC;", szSteamId, szSteamId, szBuffer[0], szBuffer[1]);
		}
		else
		{
			Format(szQuery, 1024, "SELECT db1.name, db2.steamid, db2.mapname, db2.runtimepro as overall, db1.steamid, db3.tier, (SELECT COUNT(runtimepro) FROM ck_playertimes WHERE runtimepro <= (SELECT runtimepro FROM ck_playertimes WHERE steamid = '%s' AND mapname = db2.mapname AND style = 0 AND runtimepro > -1.0 ORDER BY runtimepro) AND mapname = db2.mapname AND style = 0 AND runtimepro > -1.0) AS rank, (SELECT count(1) FROM ck_playertimes WHERE mapname = db2.mapname AND style = 0) AS total FROM ck_playertimes as db2 INNER JOIN ck_playerrank as db1 on db2.steamid = db1.steamid INNER JOIN ck_maptier AS db3 ON db2.mapname = db3.mapname WHERE db2.steamid = '%s' AND db2.style = 0 AND db2.runtimepro > -1.0 ORDER BY mapname ASC;", szSteamId, szSteamId);
		}
	}
	else
	{
		if (StrEqual(szBuffer[1], "0"))
		{
			Format(szQuery, 1024, "SELECT db1.name, db2.steamid, db2.mapname, db2.runtimepro as overall, db1.steamid, db3.tier, (SELECT COUNT(runtimepro) FROM ck_playertimes WHERE runtimepro <= (SELECT runtimepro FROM ck_playertimes WHERE steamid = '%s' AND mapname = db2.mapname AND runtimepro > -1.0 ORDER BY runtimepro) AND mapname = db2.mapname AND runtimepro > -1.0) AS rank, (SELECT count(1) FROM ck_playertimes WHERE mapname = db2.mapname) AS total FROM ck_playertimes as db2 INNER JOIN ck_playerrank as db1 on db2.steamid = db1.steamid INNER JOIN ck_maptier AS db3 ON db2.mapname = db3.mapname WHERE db2.steamid = '%s' AND db3.tier = %s AND db2.runtimepro > -1.0 ORDER BY mapname ASC;", szSteamId, szSteamId, szBuffer[0]);
		}
		else if (strlen(szBuffer[1]) > 0)
		{
			Format(szQuery, 1024, "SELECT db1.name, db2.steamid, db2.mapname, db2.runtimepro as overall, db1.steamid, db3.tier, (SELECT COUNT(runtimepro) FROM ck_playertimes WHERE runtimepro <= (SELECT runtimepro FROM ck_playertimes WHERE steamid = '%s' AND mapname = db2.mapname AND runtimepro > -1.0 ORDER BY runtimepro) AND mapname = db2.mapname AND runtimepro > -1.0) AS rank, (SELECT count(1) FROM ck_playertimes WHERE mapname = db2.mapname) AS total FROM ck_playertimes as db2 INNER JOIN ck_playerrank as db1 on db2.steamid = db1.steamid INNER JOIN ck_maptier AS db3 ON db2.mapname = db3.mapname WHERE db2.steamid = '%s' AND db3.tier >= %s AND db3.tier <= %s AND db2.runtimepro > -1.0 ORDER BY mapname ASC;", szSteamId, szSteamId, szBuffer[0], szBuffer[1]);
		}
		else
		{
			Format(szQuery, 1024, "SELECT db1.name, db2.steamid, db2.mapname, db2.runtimepro as overall, db1.steamid, db3.tier, (SELECT COUNT(runtimepro) FROM ck_playertimes WHERE runtimepro <= (SELECT runtimepro FROM ck_playertimes WHERE steamid = '%s' AND mapname = db2.mapname AND runtimepro > -1.0 ORDER BY runtimepro) AND mapname = db2.mapname AND runtimepro > -1.0) AS rank, (SELECT count(1) FROM ck_playertimes WHERE mapname = db2.mapname) AS total FROM ck_playertimes as db2 INNER JOIN ck_playerrank as db1 on db2.steamid = db1.steamid INNER JOIN ck_maptier AS db3 ON db2.mapname = db3.mapname WHERE db2.steamid = '%s' AND db2.runtimepro > -1.0 ORDER BY mapname ASC;", szSteamId, szSteamId);
		}
	}

	SQL_TQuery(g_hDb, SelectCompletedMapsCallback, szQuery, client, DBPrio_Low);
}

public void SelectCompletedMapsCallback(Handle owner, Handle hndl, const  char[] error, any client)
{
	if (hndl == null)
	{
		LogError("[Nominations] SQL Error (SelectCompletedMapsCallback): %s", error);
		return;
	}

	if (SQL_HasResultSet(hndl))
	{
		Menu menu = CreateMenu(Handler_MapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
		SetMenuTitle(menu, "Nominate Map - Completed Maps:\n    Rank         Time          Mapname");

		ArrayList excludeMaps;
		char currentMap[PLATFORM_MAX_PATH];

		if (g_Cvar_ExcludeOld.BoolValue)
		{
			excludeMaps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
			GetExcludeMapList(excludeMaps);
		}

		if (g_Cvar_ExcludeCurrent.BoolValue)
		{
			GetCurrentMap(currentMap, sizeof(currentMap));
		}

		char szSteamId[32], szMapName[128], szTime[32], szValue[128], szValue2[256];
		float time;
		int tier;
		int rank;
		int count;

		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 1, szSteamId, 32);
			SQL_FetchString(hndl, 2, szMapName, 128);
			if (!GetConVarBool(g_Cvar_IncludeAllMaps) && bIsMapGlobal(szMapName) || GetConVarBool(g_Cvar_IncludeAllMaps))
			{
				time = SQL_FetchFloat(hndl, 3);
				tier = SQL_FetchInt(hndl, 5);
				rank = SQL_FetchInt(hndl, 6);
				count = SQL_FetchInt(hndl, 7);

				FormatTimeFloat(client, time, 3, szTime, sizeof(szTime));

				if (time < 3600.0)
				Format(szTime, 32, "%s", szTime);

				char szS[32];
				char szT[32];
				char szTotal[32];
				IntToString(rank, szT, sizeof(szT));
				IntToString(count, szS, sizeof(szS));
				Format(szTotal, sizeof(szTotal), "%s%s", szT, szS);
				if (strlen(szTotal) == 6)
					Format(szValue, 128, "%i/%i    %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);
				else if (strlen(szTotal) == 5)
					Format(szValue, 128, "%i/%i      %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);
				else if (strlen(szTotal) == 4)
					Format(szValue, 128, "%i/%i        %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);
				else if (strlen(szTotal) == 3)
					Format(szValue, 128, "%i/%i          %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);
				else if (strlen(szTotal) == 2)
					Format(szValue, 128, "%i/%i           %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);
				else if (strlen(szTotal) == 1)
					Format(szValue, 128, "%i/%i            %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);
				else
					Format(szValue, 128, "%i/%i  %s | » %s - Tier %i", rank, count, szTime, szMapName, tier);

				Format(szValue2, 256, "%s - Tier %i", szMapName, tier);

				int status = MAPSTATUS_ENABLED;

				FindMap(szMapName, szMapName, sizeof(szMapName));

				char displayName[PLATFORM_MAX_PATH];
				GetMapDisplayName(szMapName, displayName, sizeof(displayName));

				if (g_Cvar_ExcludeCurrent.BoolValue)
				{
					if (StrEqual(szMapName, currentMap))
					{
						status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_CURRENT;
					}
				}
	
				/* Dont bother with this check if the current map check passed */
				if (g_Cvar_ExcludeOld.BoolValue && status == MAPSTATUS_ENABLED)
				{
					if (excludeMaps.FindString(szMapName) != -1 || excludeMaps.FindString(szValue2) != -1)
					{
						status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_PREVIOUS;
					}
				}

				AddMenuItem(menu, szValue2, szValue);
				g_mapTrie.SetValue(szMapName, status);
			}
		}
		SetMenuExitBackButton(menu, true);
		DisplayMenu(menu, client, MENU_TIME_FOREVER);

		delete excludeMaps;
	}
	else
	{
		PrintToChat(client, "No maps found");
	}
}

public void SelectIncompleteMaps(int client)
{
	char szQuery[1024];
	char szSteamId[32];

	GetClientAuthId(client, AuthId_Steam2, szSteamId, MAX_NAME_LENGTH, true);

	char szTier[16];
	char szBuffer[2][32];
	GetConVarString(g_Cvar_ServerTier, szTier, sizeof(szTier));
	ExplodeString(szTier, ".", szBuffer, 2, 32);
	if (GetConVarInt(g_Cvar_TimerType) == 1)
	{
		if (StrEqual(szBuffer[1], "0"))
		{
			Format(szQuery, 1024, "SELECT a.mapname, d.tier FROM ck_zones a INNER JOIN ck_maptier AS d ON a.mapname = d.mapname WHERE d.tier = %s AND (zonetype = 1 OR zonetype = 5) AND (SELECT runtimepro FROM ck_playertimes b WHERE b.mapname = a.mapname AND b.style = 0 AND steamid = '%s') IS NULL GROUP BY mapname ORDER BY mapname ASC", szBuffer[0],  szSteamId);
		}
		else if (strlen(szBuffer[1]) > 0)
		{
			Format(szQuery, 1024, "SELECT a.mapname, d.tier FROM ck_zones a INNER JOIN ck_maptier AS d ON a.mapname = d.mapname WHERE d.tier >= %s AND d.tier <= %s AND (zonetype = 1 OR zonetype = 5) AND (SELECT runtimepro FROM ck_playertimes b WHERE b.mapname = a.mapname AND b.style = 0 AND steamid = '%s') IS NULL GROUP BY mapname ORDER BY mapname ASC", szBuffer[0], szBuffer[1], szSteamId);
		}
		else
		{
			Format(szQuery, 1024, "SELECT a.mapname, d.tier FROM ck_zones a INNER JOIN ck_maptier AS d ON a.mapname = d.mapname WHERE (zonetype = 1 OR zonetype = 5) AND (SELECT runtimepro FROM ck_playertimes b WHERE b.mapname = a.mapname AND b.style = 0 AND steamid = '%s') IS NULL GROUP BY mapname ORDER BY mapname ASC", szSteamId);
		}
	}
	else
	{
		if (StrEqual(szBuffer[1], "0"))
		{
			Format(szQuery, 1024, "SELECT a.mapname, d.tier FROM ck_zones a INNER JOIN ck_maptier AS d ON a.mapname = d.mapname WHERE d.tier = %s AND (zonetype = 1 OR zonetype = 5) AND (SELECT runtimepro FROM ck_playertimes b WHERE b.mapname = a.mapname AND steamid = '%s') IS NULL GROUP BY mapname ORDER BY mapname ASC", szBuffer[0],  szSteamId);
		}
		else if (strlen(szBuffer[1]) > 0)
		{
			Format(szQuery, 1024, "SELECT a.mapname, d.tier FROM ck_zones a INNER JOIN ck_maptier AS d ON a.mapname = d.mapname WHERE d.tier >= %s AND d.tier <= %s AND (zonetype = 1 OR zonetype = 5) AND (SELECT runtimepro FROM ck_playertimes b WHERE b.mapname = a.mapname AND steamid = '%s') IS NULL GROUP BY mapname ORDER BY mapname ASC", szBuffer[0], szBuffer[1], szSteamId);
		}
		else
		{
			Format(szQuery, 1024, "SELECT a.mapname, d.tier FROM ck_zones a INNER JOIN ck_maptier AS d ON a.mapname = d.mapname WHERE (zonetype = 1 OR zonetype = 5) AND (SELECT runtimepro FROM ck_playertimes b WHERE b.mapname = a.mapname AND steamid = '%s') IS NULL GROUP BY mapname ORDER BY mapname ASC", szSteamId);
		}
	}

	SQL_TQuery(g_hDb, SelectIncompleteMapsCallback, szQuery, client, DBPrio_Low);
}

public void SelectIncompleteMapsCallback(Handle owner, Handle hndl, const  char[] error, any client)
{
	if (hndl == null)
	{
		LogError("[Nominations] SQL Error (SelectIncompleteMapsCallback): %s", error);
		return;
	}

	if (SQL_HasResultSet(hndl))
	{
		Menu menu = CreateMenu(Handler_MapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
		SetMenuTitle(menu, "Nominate Map - Incomplete Maps:\n");

		ArrayList excludeMaps;
		char currentMap[PLATFORM_MAX_PATH];

		if (g_Cvar_ExcludeOld.BoolValue)
		{
			excludeMaps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
			GetExcludeMapList(excludeMaps);
		}

		if (g_Cvar_ExcludeCurrent.BoolValue)
		{
			GetCurrentMap(currentMap, sizeof(currentMap));
		}

		char szMapName[128], szValue[256];
		int tier;

		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, szMapName, 128);
			tier = SQL_FetchInt(hndl, 1);
			if (!GetConVarBool(g_Cvar_IncludeAllMaps) && bIsMapGlobal(szMapName) || GetConVarBool(g_Cvar_IncludeAllMaps))
			{
				Format(szValue, 256, "%s - Tier %i", szMapName, tier);

				int status = MAPSTATUS_ENABLED;

				FindMap(szMapName, szMapName, sizeof(szMapName));

				char displayName[PLATFORM_MAX_PATH];
				GetMapDisplayName(szMapName, displayName, sizeof(displayName));

				if (g_Cvar_ExcludeCurrent.BoolValue)
				{
					if (StrEqual(szMapName, currentMap))
					{
						status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_CURRENT;
					}
				}

				/* Dont bother with this check if the current map check passed */
				if (g_Cvar_ExcludeOld.BoolValue && status == MAPSTATUS_ENABLED)
				{
					if (excludeMaps.FindString(szMapName) != -1 || excludeMaps.FindString(szValue) != -1)
					{
						status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_PREVIOUS;
					}
				}

				AddMenuItem(menu, szValue, szValue);
				g_mapTrie.SetValue(szMapName, status);
			}
		}
		SetMenuExitBackButton(menu, true);
		DisplayMenu(menu, client, MENU_TIME_FOREVER);

		delete excludeMaps;
	}
}

public void SelectMapList()
{
	char szQuery[256];

	char szTier[16];
	char szBuffer[2][32];
	GetConVarString(g_Cvar_ServerTier, szTier, sizeof(szTier));
	ExplodeString(szTier, ".", szBuffer, 2, 32);

	if (StrEqual(szBuffer[1], "0"))
	{
		Format(szQuery, 256, "SELECT mapname, tier FROM ck_maptier WHERE mapname LIKE '%csurf%c' AND tier = %s", PERCENT, PERCENT, szBuffer[0]);
	}
	else if (strlen(szBuffer[1]) > 0)
	{
		Format(szQuery, 256, "SELECT mapname, tier FROM ck_maptier WHERE mapname LIKE '%csurf%c' AND tier >= %s AND tier <= %s;", PERCENT, PERCENT, szBuffer[0], szBuffer[1]);
	}
	else
	{
		Format(szQuery, 256, "SELECT mapname, tier FROM ck_maptier WHERE mapname LIKE '%csurf%c';", PERCENT, PERCENT);
	}

	SQL_TQuery(g_hDb, SelectMapListCallback, szQuery, DBPrio_Low);
}

public void SelectMapListCallback(Handle owner, Handle hndl, const  char[] error, any data)
{
	if (hndl == null)
	{
		LogError("[Nominations] SQL Error (SelectMapListCallback): %s", error);
		return;
	}

	if (SQL_HasResultSet(hndl))
	{
		g_MapList.Clear();

		char szMapName[128];
		int tier;
		char szValue[256];
		while (SQL_FetchRow(hndl))
		{
			SQL_FetchString(hndl, 0, szMapName, 128);
			tier = SQL_FetchInt(hndl, 1);
			if (!GetConVarBool(g_Cvar_IncludeAllMaps) && bIsMapGlobal(szMapName) || GetConVarBool(g_Cvar_IncludeAllMaps))
			{
				Format(szValue, 256, "%s - Tier %i", szMapName, tier);
				g_MapList.PushString(szValue);
			}
		}
	}

	BuildMapMenu();
}

public bool bIsMapGlobal(char[] sMapName)
{
	if (g_GlobalMapList != null)
	{
		for (int i = 0; i < g_GlobalMapList.Length; i++)
		{
			char sCurrentMap[256];
			g_GlobalMapList.GetString(i, sCurrentMap, sizeof(sCurrentMap));
			
			if (StrEqual(sCurrentMap, sMapName)) 
				return true;
		}
	}
	return false;
}

public void FormatTimeFloat(int client, float time, int type, char[] string, int length)
{
	char szMilli[16];
	char szSeconds[16];
	char szMinutes[16];
	char szHours[16];
	char szMilli2[16];
	char szSeconds2[16];
	char szMinutes2[16];
	int imilli;
	int imilli2;
	int iseconds;
	int iminutes;
	int ihours;
	time = FloatAbs(time);
	imilli = RoundToZero(time * 100);
	imilli2 = RoundToZero(time * 10);
	imilli = imilli % 100;
	imilli2 = imilli2 % 10;
	iseconds = RoundToZero(time);
	iseconds = iseconds % 60;
	iminutes = RoundToZero(time / 60);
	iminutes = iminutes % 60;
	ihours = RoundToZero((time / 60) / 60);

	if (imilli < 10)
		Format(szMilli, 16, "0%dms", imilli);
	else
		Format(szMilli, 16, "%dms", imilli);
	if (iseconds < 10)
		Format(szSeconds, 16, "0%ds", iseconds);
	else
		Format(szSeconds, 16, "%ds", iseconds);
	if (iminutes < 10)
		Format(szMinutes, 16, "0%dm", iminutes);
	else
		Format(szMinutes, 16, "%dm", iminutes);


	Format(szMilli2, 16, "%d", imilli2);
	if (iseconds < 10)
		Format(szSeconds2, 16, "0%d", iseconds);
	else
		Format(szSeconds2, 16, "%d", iseconds);
	if (iminutes < 10)
		Format(szMinutes2, 16, "0%d", iminutes);
	else
		Format(szMinutes2, 16, "%d", iminutes);
	//Time: 00m 00s 00ms
	if (type == 0)
	{
		Format(szHours, 16, "%dm", iminutes);
		if (ihours > 0)
		{
			Format(szHours, 16, "%d", ihours);
			Format(string, length, "%s:%s:%s.%s", szHours, szMinutes2, szSeconds2, szMilli2);
		}
		else
		{
			Format(string, length, "%s:%s.%s", szMinutes2, szSeconds2, szMilli2);
		}
	}
	//00m 00s 00ms
	if (type == 1)
	{
		Format(szHours, 16, "%dm", iminutes);
		if (ihours > 0)
		{
			Format(szHours, 16, "%dh", ihours);
			Format(string, length, "%s %s %s %s", szHours, szMinutes, szSeconds, szMilli);
		}
		else
			Format(string, length, "%s %s %s", szMinutes, szSeconds, szMilli);
	}
	else
		//00h 00m 00s 00ms
	if (type == 2)
	{
		imilli = RoundToZero(time * 1000);
		imilli = imilli % 1000;
		if (imilli < 10)
			Format(szMilli, 16, "00%dms", imilli);
		else
			if (imilli < 100)
				Format(szMilli, 16, "0%dms", imilli);
			else
				Format(szMilli, 16, "%dms", imilli);
		Format(szHours, 16, "%dh", ihours);
		Format(string, 32, "%s %s %s %s", szHours, szMinutes, szSeconds, szMilli);
	}
	else
		//00:00:00
	if (type == 3)
	{
		if (imilli < 10)
			Format(szMilli, 16, "0%d", imilli);
		else
			Format(szMilli, 16, "%d", imilli);
		if (iseconds < 10)
			Format(szSeconds, 16, "0%d", iseconds);
		else
			Format(szSeconds, 16, "%d", iseconds);
		if (iminutes < 10)
			Format(szMinutes, 16, "0%d", iminutes);
		else
			Format(szMinutes, 16, "%d", iminutes);
		if (ihours > 0)
		{
			Format(szHours, 16, "%d", ihours);
			Format(string, length, "%s:%s:%s:%s", szHours, szMinutes, szSeconds, szMilli);
		}
		else
			Format(string, length, "%s:%s:%s", szMinutes, szSeconds, szMilli);
	}
	//Time: 00:00:00
	if (type == 4)
	{
		if (imilli < 10)
			Format(szMilli, 16, "0%d", imilli);
		else
			Format(szMilli, 16, "%d", imilli);
		if (iseconds < 10)
			Format(szSeconds, 16, "0%d", iseconds);
		else
			Format(szSeconds, 16, "%d", iseconds);
		if (iminutes < 10)
			Format(szMinutes, 16, "0%d", iminutes);
		else
			Format(szMinutes, 16, "%d", iminutes);
		if (ihours > 0)
		{
			Format(szHours, 16, "%d", ihours);
			Format(string, length, "Time: %s:%s:%s", szHours, szMinutes, szSeconds);
		}
		else
			Format(string, length, "Time: %s:%s", szMinutes, szSeconds);
	}
	// goes to  00:00
	if (type == 5)
	{
		if (imilli < 10)
			Format(szMilli, 16, "0%d", imilli);
		else
			Format(szMilli, 16, "%d", imilli);
		if (iseconds < 10)
			Format(szSeconds, 16, "0%d", iseconds);
		else
			Format(szSeconds, 16, "%d", iseconds);
		if (iminutes < 10)
			Format(szMinutes, 16, "0%d", iminutes);
		else
			Format(szMinutes, 16, "%d", iminutes);
		if (ihours > 0)
		{

			Format(szHours, 16, "%d", ihours);
			Format(string, length, "%s:%s:%s:%s", szHours, szMinutes, szSeconds, szMilli);
		}
		else
			if (iminutes > 0)
				Format(string, length, "%s:%s:%s", szMinutes, szSeconds, szMilli);
			else
				Format(string, length, "%s:%ss", szSeconds, szMilli);
	}
}
