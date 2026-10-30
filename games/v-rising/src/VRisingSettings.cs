// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.IO;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace NucleusLocalTools
{
    public static class VRisingSettings
    {
        public static void Prepare(string root, string source, int width, int height)
        {
            if (width < 640 || height < 480) throw new ArgumentException("Invalid resolution");
            string target = Path.Combine(root, "Settings", "v4", "ClientSettings.json");
            if (String.Equals(Path.GetFullPath(target), Path.GetFullPath(source), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Refusing to write the original Steam settings");
            string input = File.Exists(target) ? target : source;
            if (!File.Exists(input)) throw new FileNotFoundException("Run the original game and complete its initial setup first", input);
            var settings = JObject.Parse(File.ReadAllText(input));
            Section(settings, "GameClient")["AnalyticsEnabled"] = false;
            Section(settings, "GameClient")["HasSeenCinematic"] = true;
            Section(settings, "Interface")["Language"] = "russian";
            var graphics = Section(settings, "GraphicSettings");
            graphics["Resolution"] = new JObject(new JProperty("x", width), new JProperty("y", height));
            graphics["WindowMode"] = 3;
            // Preserve the original setup and age-gate state, including empty arrays.
            string output = settings.ToString(Formatting.Indented);
            JObject.Parse(output);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            string temporary = target + ".nucleus-tmp";
            File.WriteAllText(temporary, output, new UTF8Encoding(false));
            if (File.Exists(target)) File.Replace(temporary, target, target + ".previous");
            else File.Move(temporary, target);
        }

        private static JObject Section(JObject root, string name)
        {
            var section = root[name] as JObject;
            if (section == null) { section = new JObject(); root[name] = section; }
            return section;
        }
    }
}
