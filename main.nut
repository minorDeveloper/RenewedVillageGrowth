require("version.nut");
require("cargo.nut");
require("town.nut");
require("story.nut");
require("strings.nut");

// Import SuperLib for GameScript
import("util.superlib", "SuperLib", 40);
Log <- SuperLib.Log;
Helper <- SuperLib.Helper;

class MainClass extends GSController
{
	towns = null;
	current_date = null;
	current_week = null;
	current_month = null;
	current_year = null;
	gs_init_done = null;
	load_saved_data = null;
	current_save_version = null;
	limit_growth = null;
	actual_town_info_mode = null;

	constructor() {
		this.towns = null;
		this.current_date = 0;
		this.current_week = 0;
		this.current_month = 0;
		this.current_year = 0;
		this.gs_init_done = false;
		this.current_save_version = 6;    // Ensures compatibility between revisions
		this.load_saved_data = false;
		this.limit_growth = false;
		this.actual_town_info_mode = 0;
		::TownDataTable <- {};
		::SettingsTable <- {
			industry_NewGRF = GSController.GetSetting("industry_NewGRF"),
			use_town_sign = GSController.GetSetting("use_town_sign")
		}
	}
}

function MainClass::Start()
{
	// Initializing the script
	local start_tick = GSController.GetTick();
	GSGame.Pause();
	Log.Info("Growth limiter initialisation...", Log.LVL_INFO);
	this.InitCityLimiter();
	Log.Info("Script initialisation...", Log.LVL_INFO);
	this.Init();
	GSGame.Unpause();

	local setup_duration = GSController.GetTick() - start_tick;
	Log.Info("Game setup done.", Log.LVL_INFO);
	Log.Info("Setup took " + setup_duration + " ticks.", Log.LVL_DEBUG);
	Log.Info("Happy playing !", Log.LVL_INFO);

	// Wait for the game to start
	GSController.Sleep(1);

	// Create and fill StoryBook. This can't be done before OTTD is ready.
	local story_editor = StoryEditor();
	story_editor.CreateStoryBook();

	// Main loop
	local past_system_time = GSDate.GetSystemTime();
	while (true) {
		local town_info_mode = GSController.GetSetting("town_info_mode");
		if (this.actual_town_info_mode != town_info_mode) {
			this.actual_town_info_mode = town_info_mode;
			foreach (town in this.towns) {
				town.UpdateTownText(this.actual_town_info_mode);
			}
			continue;
		}
		
		local system_time = GSDate.GetSystemTime();
		if (1 == this.actual_town_info_mode && system_time - past_system_time > 3) {
			past_system_time = system_time;
			
			foreach (town in this.towns) {
				town.UpdateTownText(this.actual_town_info_mode);
			}
		}
		
		this.HandleEvents();
		this.ManageTowns();	
	}
}

function MainClass::Init()
{
	// Check game settings
	GSGameSettings.SetValue("economy.town_growth_rate", 2);
	GSGameSettings.SetValue("economy.fund_buildings", 0);

	// Set current date
	this.current_date = this.current_week = GSDate.GetCurrentDate();
	this.current_month = GSDate.GetMonth(this.current_date);
	this.current_year = GSDate.GetYear(this.current_date);

	// Initialize cargo lists and variables
	InitCargoLists();
	/* Check whether saved data are in the current save
	 * format.
	 */
	if (!load_saved_data) {
		Helper.ClearAllSigns();
	}

	// Create the towns list
	Log.Info("Create town list ... (can take a while on large maps)", Log.LVL_INFO);
	this.towns = this.CreateTownList();

	// Ending initialization
	this.gs_init_done = true;

	// Now we can free ::TownDataTable
	::TownDataTable = null;
}

function MainClass::InitCityLimiter()
{
	// Read the openttd.cfg Town Growth Rate setting first.
	// If the map is set to disallow town growth at all, this script
	// won't do anything further.
	if (GSGameSettings.IsValid("town_growth_rate")) {
		if (! GSGameSettings.GetValue("town_growth_rate") ) {
			GSLog.Warning("You must set town growth in advanced setting to something other than None. This script is now exiting.");
			this.limit_growth = false;
			return;
		}
	}
	
	// If both the min value for pax and mail are set to 0,
	// this script will do no good.  Stop the script.
	local paxRequired = GSController.GetSetting("min_transport_pax").tofloat();
	local mailRequired = GSController.GetSetting("min_transport_mail").tofloat();
	
	if (paxRequired == 0 && mailRequired == 0) {
		this.limit_growth = false;
		return;
	}
	
	this.limit_growth = true;
	return;
}

function MainClass::HandleEvents()
{
	while (GSEventController.IsEventWaiting()) {
		local event = GSEventController.GetNextEvent();

		switch (event.GetEventType()) {
		// On town founding, add a new GoalTown instance
		case GSEvent.ET_TOWN_FOUNDED:
			event = GSEventTownFounded.Convert(event);
			local town_id = event.GetTownID();
			if (GSTown.IsValidTown(town_id)) this.UpdateTownList(town_id);
			break;

		default: break;
		}
	}
}

function MainClass::Save()
{
	Log.Info("Saving data...", Log.LVL_INFO);
	local save_table = {};

	/* If some permanent setting has been changed in scenario
	 * editor, do not save anything.
	 */
	if ((::SettingsTable.industry_NewGRF != GSController.GetSetting("industry_NewGRF")) ||
	    (::SettingsTable.use_town_sign != GSController.GetSetting("use_town_sign"))) {
		Log.Info("Some permanent setting changed. Not saving town data.", Log.LVL_INFO);
		return save_table;
	}

	/* If the script isn't yet initialized, we can't retrieve data
	 * from GoalTown instances. Thus, simply use the original
	 * loaded table. Otherwise we build the table with town data.
	 */
	save_table.town_data_table <- {};
	if (!this.gs_init_done) {
		save_table.town_data_table <- ::TownDataTable;
	} else {
		foreach (i, town in this.towns)
		{
			save_table.town_data_table[town.id] <- town.SavingTownData();
		}
		// Also store a savegame version flag
		save_table.save_version <- this.current_save_version;
	}

	return save_table;
}

function MainClass::Load(version, saved_data)
{
	Log.Info("Loading data...", Log.LVL_INFO);
	// Loading town data. Only load data if the savegame version matches.
	if (saved_data.rawin("save_version") && saved_data.save_version == this.current_save_version) {
		this.load_saved_data = true;
		foreach (townid, town_data in saved_data.town_data_table) {
			::TownDataTable[townid] <- town_data;
		}
	}
	else {
		Log.Info("Data format doesn't match with current version. Resetting.", Log.LVL_INFO);
	}
}

/* Make a squirrel array of GoalTown instances (towns_array). For each
 * town, an instance of GoalTown is created to store the data related
 * to that town.
 */
function MainClass::CreateTownList()
{
	local towns_list = GSTownList();
	local towns_array = [];

	foreach (t, _ in towns_list) {
		towns_array.append(GoalTown(t, this.load_saved_data, this.limit_growth));
	}

	return towns_array;
}

/* Function called on town creation. We need to add a now GoalTown
 * instance to the this.towns array. The array order doesn't matter,
 * since we never use the array index, only its values.
 */
function MainClass::UpdateTownList(town_id)
{
	this.towns.append(GoalTown(town_id, false, this.limit_growth));
	Log.Info("New town founded: "+GSTown.GetName(town_id)+" (id: "+town_id+")", Log.LVL_DEBUG);
}

/* Function called periodically (each 74 ticks) to manage
 * towns and other stuff.
 */
function MainClass::ManageTowns()
{
	// Run the daily functions
	local date = GSDate.GetCurrentDate();
	local diff_date = date - this.current_date;
	if (diff_date == 0) {
		return;
	} else {
		this.current_date = date;
	}

	// Run the monthly functions
	local month = GSDate.GetMonth(date);
	local diff_month = month - this.current_month;
	if (diff_month == 0) {
		return;
	} else {
		local month_tick = GSController.GetTick();
		Log.Info("Starting Monthly Updates...", Log.LVL_INFO);
		
		local eternal_love = GSController.GetSetting("eternal_love");
		local eternal_love_rating = 0;
		switch (eternal_love) {
			case(1): // Outstanding
				eternal_love_rating = 1000;
				break;
			case(2): // Good
				eternal_love_rating = 400;
				break;
			case(3): // Poor
				eternal_love_rating = 0;
				break;
		}

		foreach (town in this.towns) {
			town.ManageTownLimiting();
			town.MonthlyManageTown();
			if (this.actual_town_info_mode > 1) {
				town.UpdateTownText(this.actual_town_info_mode);
			}
			
			if (eternal_love > 0) {
				town.EternalLove(eternal_love_rating);
			}
		}
		
		this.current_month = month;
		local month_tick_duration = GSController.GetTick() - month_tick;
		Log.Info("Monthly Update took "+month_tick_duration+" ticks.", Log.LVL_DEBUG);
	}

	// Run the yearly functions - Nothing to do for now, so we leave it out
	/*local year = GSDate.GetYear(date);
	local diff_year = year - this.current_year;
	if ( diff_year == 0) return;
	else
	{
		GSLog.Info("Starting Yearly Updates");
		this.current_year = year
	}*/
}