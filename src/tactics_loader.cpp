/*
 * This file is part of mod-lonelyice-tactics. Copyright (C) LonelyIceProject.
 *
 * This program is free software; you can redistribute it and/or modify it under the terms of the
 * GNU General Public License as published by the Free Software Foundation; either version 2 of the
 * License, or (at your option) any later version.
 */
void AddTacticsEngineScripts();
void AddTacticsDataScripts();
void AddTacticsSimScripts();
void AddTacticsMetricsScripts();
void AddTacticsMirrorScripts();
void AddTacticsBagCleanupScripts();

// Static module entry (modules/mod-lonelyice-tactics) and plugin entry (plugin/plugin.cpp).
void Addmod_lonelyice_tacticsScripts()
{
    AddTacticsEngineScripts();
    AddTacticsDataScripts();
    AddTacticsSimScripts();
    AddTacticsMetricsScripts();
    AddTacticsMirrorScripts();
    AddTacticsBagCleanupScripts();
}
