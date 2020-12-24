/*
 * Copy me if you can.
 * by N00byEdge, original by 20h
 */

#define _BSD_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/sysinfo.h>

#include <X11/Xlib.h>

static Display *dpy;

char *spinChars = "|/-\\";
int currSpinChar = 0;

char getNextSpinChar() {
  char c = spinChars[currSpinChar++];
  if(currSpinChar == 4)
    currSpinChar = 0;
  return c;
}

void updateweather() {
  
}

char *smprintf(char *fmt, ...) {
  va_list fmtargs;
  char *ret;
  int len;

  va_start(fmtargs, fmt);
  len = vsnprintf(NULL, 0, fmt, fmtargs);
  va_end(fmtargs);

  ret = malloc(++len);
  if (ret == NULL) {
    perror("malloc");
    exit(1);
  }

  va_start(fmtargs, fmt);
  vsnprintf(ret, len, fmt, fmtargs);
  va_end(fmtargs);

  return ret;
}

void setstatus(char *str) {
  XStoreName(dpy, DefaultRootWindow(dpy), str);
  XSync(dpy, False);
}

struct Procstat{
  char cpuname[256];
  unsigned long long
    user,
    nice,
    system,
    idle,
    iowait,
    irq,
    softirq,
    steal,
    guest,
    guest_nice,
    sum
  ;
};

struct Procstat lastStat = {.sum = 1, .idle = 1};

void getStat(struct Procstat *stat) {
  FILE *fp = fopen("/proc/stat", "r");

  fscanf(fp, "%s %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
    stat->cpuname, &stat->user, &stat->nice, &stat->system, &stat->idle,
    &stat->iowait, &stat->irq, &stat->softirq, &stat->steal, &stat->guest,
    &stat->guest_nice);

  fclose(fp);

  stat->sum = stat->user + stat->nice + stat->system + stat->idle + stat->iowait +
             stat->irq + stat->softirq + stat->steal + stat->guest + stat->guest_nice;
}

char *getperf() {
  struct Procstat stat;
  getStat(&stat);

  unsigned long long totJiffies = stat.sum - lastStat.sum;
  if(totJiffies < 1)
    totJiffies = 1;
  unsigned long long usedJiffies = totJiffies - stat.idle + lastStat.idle;
  unsigned long long usage = (usedJiffies * 100)/totJiffies;

  lastStat = stat;

  struct sysinfo si;
  if(sysinfo(&si) < 0) {
    si.totalram = 1;
    si.freeram = -1;
  }

  int ramusage = ((si.totalram - si.freeram) * 100)/si.totalram;
  return smprintf("CPU: %03llu%% Ram: %03d%%", usage, ramusage);
}

char *readfile(char *base, char *file){
  char *path, line[513];
  FILE *fd;

  memset(line, 0, sizeof(line));

  path = smprintf("%s/%s", base, file);
  fd = fopen(path, "r");
  free(path);
  if (fd == NULL)
    return NULL;

  if (fgets(line, sizeof(line)-1, fd) == NULL)
    return NULL;
  fclose(fd);

  return smprintf("%s", line);
}

char *getbattery() {
  char *co, *status, *base;
  int descap, remcap;

#if defined(HOSTNAMEmba)
  base = "/sys/class/power_supply/BAT0";
#elif defined(HOSTNAMEsurfass)
  base = "/sys/class/power_supply/BAT1";
#else
  return smprintf("");
#endif

  descap = -1;
  remcap = -1;

  co = readfile(base, "present");
  if (co == NULL)
    return smprintf("");
  if (co[0] != '1') {
    free(co);
    return smprintf("not present");
  }
  free(co);
  co = readfile(base, "charge_full");
  if (co == NULL) {
    co = readfile(base, "energy_full");
    if (co == NULL)
      return smprintf(" BAT_ERR2");
  }
  sscanf(co, "%d", &descap);
  free(co);

  co = readfile(base, "charge_now");
  if (co == NULL) {
    co = readfile(base, "energy_now");
    if (co == NULL)
      return smprintf(" BAT_ERR3");
  }
  sscanf(co, "%d", &remcap);
  free(co);

  co = readfile(base, "status");
  if (!strncmp(co, "Discharging", 11)) {
    status = "-";
  } else if(!strncmp(co, "Charging", 8)) {
    status = "+";
  } else if(!strncmp(co, "Full", 4)) {
    status = "^";
  } else {
    status = "!";
  }

  if (remcap < 1 || descap < 1)
    return smprintf(" Bat: invalid");

  return smprintf(" Bat: %03d%%%s", ((remcap*100) / descap), status);
}

char *getTime() {
  char buf[129];
  time_t tim;
  struct tm *timtm;

  setenv("TZ", "Europe/Stockholm", 1);
  tim = time(NULL);
  timtm = localtime(&tim);
  if (timtm == NULL)
    return smprintf("");

  if (!strftime(buf, sizeof(buf)-1, " Week %V %a %d %b %H:%M:%S %Y", timtm)) {
    fprintf(stderr, "strftime == 0\n");
    return smprintf("");
  }

  return smprintf("%s", buf);
}

char *gettemperature(char *base, char *sensor) {
  char *co;

  co = readfile(base, sensor);
  if (co == NULL)
    return smprintf("");
  return smprintf("%02.0f°C", atof(co) / 1000);
}

int main() {
  getStat(&lastStat);
  char *status, *perf, *bat, *loctime , spinchar;

  if (!(dpy = XOpenDisplay(NULL))) {
    fprintf(stderr, "dwmstatus: cannot open display.\n");
    return 1;
  }

  for (;;sleep(1)) {
    perf = getperf();
    bat = getbattery();
    loctime = getTime();

    //for(int i = 0; i < 10; ++i) {
      spinchar = getNextSpinChar();
      status = smprintf("%s%s%s %c", perf, bat, loctime, spinchar);
      setstatus(status);
      //usleep(100000);
    //}

    free(perf);
    free(bat);
    free(loctime);
    free(status);
  }

  XCloseDisplay(dpy);

  return 0;
}

