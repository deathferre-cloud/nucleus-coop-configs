// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

internal static class NucleusAudioCheck
{
    static int Main(string[] args)
    {
        try
        {
            bool test = args.Length > 0 && args[0] == "--test";
            string[] devices = test ? System.Linq.Enumerable.ToArray(System.Linq.Enumerable.Skip(args, 1)) : args;
            if (devices.Length == 0) { Console.WriteLine("Usage: AudioCheck [--test] endpointId1 endpointId2 ..."); return 2; }
            using(var enumerator = new MMDeviceEnumerator())
            {
                for(int n=0;n<devices.Length;n++)
                using(var device=enumerator.GetDevice(devices[n]))
                {
                    Console.WriteLine("PLAYER " +(n+1)+" | "+device.FriendlyName+" | "+device.State+" | "+device.ID);
                    if(device.State!=DeviceState.Active) continue;
                    var sessions=device.AudioSessionManager.Sessions;
                    for(int i=0;i<sessions.Count;i++)
                    {
                        var session=sessions[i];
                        string name;
                        try { name=Process.GetProcessById((int)session.GetProcessID).ProcessName; } catch { name="system"; }
                        Console.WriteLine("  pid="+session.GetProcessID+" name="+name+" state="+session.State+" mute="+session.SimpleAudioVolume.Mute+" volume="+session.SimpleAudioVolume.Volume+" peak="+session.AudioMeterInformation.MasterPeakValue);
                    }
                    if(test)
                    {
                        for(int k=0;k<=n;k++) { Tone(device, n==0 ? 660 : 880); Thread.Sleep(180); }
                        Thread.Sleep(700);
                    }
                }
            }
            return 0;
        }
        catch(Exception error) { Console.WriteLine(error); return 1; }
    }
    private static void Tone(MMDevice device,int frequency)
    {
        const int rate=44100, frames=17640;
        using(var bytes=new MemoryStream())
        {
            var writer=new BinaryWriter(bytes);
            for(int i=0;i<frames;i++)
            {
                double envelope=Math.Min(1.0,Math.Min(i,frames-1-i)/(rate*0.015));
                short sample=(short)(Math.Sin(i*2*Math.PI*frequency/rate)*32767*0.12*envelope);
                writer.Write(sample);writer.Write(sample);
            }
            bytes.Position=0;
            using(var stream=new RawSourceWaveStream(bytes,new WaveFormat(rate,16,2)))
            using(var output=new WasapiOut(device,AudioClientShareMode.Shared,true,100))
            {
                output.Init(stream);output.Play();
                var timer=Stopwatch.StartNew();
                while(output.PlaybackState==PlaybackState.Playing && timer.ElapsedMilliseconds<3000) Thread.Sleep(30);
            }
        }
    }
}
