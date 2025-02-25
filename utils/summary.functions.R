library("stringr")  

create_time_series = function(dates, h_data = NULL, state_code, state_name = NULL, daily.data.csv_and_xlsx = 0, json = 0, historic.data = 0)
{
  
  data = NULL
  
  for(t in 1:length(dates)){
    
    Date = dates[t]
    #print(Date)
    
    #
    # read daily update 
    
    #if csv or xlsx
    if(daily.data.csv_and_xlsx){
      file_format = ".csv"
      if(state_code %in% c("TX")) file_format = ".xlsx"
      file = file.path(path_to_data, Date, paste0(state_name, file_format))
      tmp = as.data.table( do.call(paste0("read.", state_code, ".file"), list(file, Date)) )
    }
    
    #if json
    if(json)
    {
      res = read_json(Date, state_name, state_code, data)
      json_data = res[[1]]; tmp = res[[2]]
    }
    
    # if select Date for historical data 
    if(historic.data)
    {
      tmp = as.data.table( subset(h_data, date == Date) )
    }
    data = rbind(data, tmp)
  }
  
  
  return(data)
}

ensure_increasing_cumulative_deaths = function(dates, h_data, check_difference=1)
{
  
  for(t in 1:length(dates)){
    
    Date = rev(dates)[t]
    print(Date)
    #
    # check if cumulative death is strictly decreasing from last date to first date
    
    for(age_group in unique(h_data$age)){
      
      for(Code in unique(h_data$code)){
        
        if(Date < max(dates)){
          
          # if cumulative date at date t < date t - 1, fix cum deaths at date t - 1 to the one at date t.
          if(h_data[age == age_group & date == Date & code == Code, cum.deaths] > h_data[age == age_group & date == rev(dates)[t-1] & code == Code, cum.deaths]){
            difference = h_data[age == age_group & date == Date & code == Code, cum.deaths] - h_data[age == age_group & date == rev(dates)[t-1] & code == Code, cum.deaths]
            if(difference > 60 & check_difference) stop(paste0("!!! Cumulative deaths decreased from one day to the next by more than 50, check your data !!! ", age_group, ' ',
                                            difference, ' ',
                                            h_data[age == age_group & date == Date & code == Code, cum.deaths], ' ',
                                            h_data[age == age_group & date == rev(dates)[t-1] & code == Code, cum.deaths]) )
            h_data[age == age_group & date == Date & code == Code,]$cum.deaths = h_data[age == age_group & date == rev(dates)[t-1] & code == Code, cum.deaths]
          }
          
        }
        
      }
    }
  }
  
  return(h_data)
}

find_daily_deaths = function(dates, h_data, state_code)
{
  
  first.day = min(dates)
  
  data = NULL
  
  for(t in 1:length(dates)){
    
    Date = dates[t]
    #print(Date)
    
    #
    # read daily daily update 
    tmp = as.data.table( subset(h_data, date == Date) )
    
    for(age_group in tmp$age){
      
      if(Date > first.day){
        # compute daily death
        cum.death.t_1 = tmp[age == age_group & date == Date,]$cum.deaths
        cum.death.t_0 =  data[age == age_group & date == (Date-1),]$cum.deaths
        daily.deaths = cum.death.t_1 - cum.death.t_0 
        
        # if there is missing data at t-1
        if((Date - 1) %notin% dates){
         
          n.lost.days = as.numeric(Date - dates[which(dates == Date)-1] -1)
          lost.days = Date - c(n.lost.days:1)
          cum.death.t_lag = tmp[age == age_group & date == Date,]$cum.deaths
          cum.death.t_0 =  data[age == age_group & date == (Date-n.lost.days-1),]$cum.deaths

          # find monthly death before missing data
          df = subset(data, date == dates[t-1])
          df = df[order(age)]
          df_last_month = subset(data, date == dates[max(1,t-32)] )
          df_last_month = df_last_month[order(age)]
          df[, monthly_deaths := cum.deaths - df_last_month$cum.deaths]
          stopifnot(all(df$monthly_deaths >= 0))
          
          # find age proportion over the last month
          var_monthly_deaths = "monthly_deaths"
          if(sum(df$monthly_deaths) == 0) var_monthly_deaths = 'cum.deaths'
          df[, prop.deaths := get(var_monthly_deaths) / sum(get(var_monthly_deaths))]
          if(sum(df$cum.deaths) == 0) df[, prop.deaths := 0]
          df = subset(df, age == age_group)
          df = select(df, age, prop.deaths, code)
          
          # find missing days by using un-stratified JHU data and age proportion
          data_missing_days = generate_daily_deaths_missing_days(state_code = state_code, 
                                                                 dates_missing = seq.Date(dates[t-1]+1, dates[t] - 1, by = 'day'),
                                                                 prop_deaths_df = df,
                                                                 max_deaths = cum.death.t_lag - cum.death.t_0)
          data_missing_days[, cum.deaths := round(cum.death.t_0 + cumsum(daily.deaths))]
          
          # find daily deaths
          daily.deaths = cum.death.t_lag - cum.death.t_0 - sum(data_missing_days$daily.deaths)
          
          # smooth
          if(n.lost.days > 4 & daily.deaths > max(data_missing_days$daily.deaths)*1.2){
            #increment = floor((cum.death.t_lag - cum.death.t_0)/n.lost.days - median(data_missing_days$daily.deaths) - max(data_missing_days$daily.deaths)/2)
            increment = floor((daily.deaths - max(data_missing_days$daily.deaths))/n.lost.days)
            
            if(increment > 0) {
              data_missing_days$daily.deaths = data_missing_days$daily.deaths + increment
              data_missing_days[, cum.deaths := round(cum.death.t_0 + cumsum(daily.deaths))]
              daily.deaths = cum.death.t_lag - cum.death.t_0 - sum(data_missing_days$daily.deaths)
            }

          }
          
          stopifnot(nrow(data_missing_days) == n.lost.days)
          data = rbind(data, data_missing_days)
        }
        
        if(daily.deaths < 0){
          print(increment)
          print(data_missing_days)
          print(daily.deaths)
        }
        stopifnot(daily.deaths >= 0)
        
        tmp[which(tmp$age == age_group & tmp$date == Date),]$daily.deaths = daily.deaths
        
        diff = daily.deaths + subset(data, date == Date -1 & age == age_group)$cum.deaths == subset(data, date == Date & age == age_group )$cum.deaths
        stopifnot(diff == 1)
      }
      
    }
    
    data = rbind(data, tmp)
  }
  
  # overwrite cumulative deaths
  data_processed = data %>%
    group_by(age) %>%
    mutate(cum.deaths.first.day  = cum.deaths[which.min(cum.deaths)], 
           cum.deaths = cumsum(replace_na(daily.deaths, 0)) + cum.deaths.first.day) %>%
    select(-c(cum.deaths.first.day))

  # sanity check: cumulative day on last day are equal to the one provided by the DoH
  sanity_check(data, data_processed, max(dates))
  
  # sanity check: no missing dates
  stopifnot(all(seq.Date(min(data$date), max(data$date), by = 'day') %in% unique(data$date)))
  
  # Reorder data
  data_processed <- with(data, data[order(data_processed, age, cum.deaths, daily.deaths, code), ])
  data_processed <- data_processed[, c("date", "age", "cum.deaths", "daily.deaths", "code")]
  
  return(data)
}

generate_daily_deaths_missing_days= function(state_code, dates_missing, prop_deaths_df, max_deaths){
  if(state_code == 'NYC'){
    death_data = as.data.table( read.csv(path_to_NYC_data) )
    death_data[, date := as.Date(date_of_interest, format = '%m/%d/%Y')]
    death_data[, code := 'NYC']
    setnames(death_data,'DEATH_COUNT', 'daily_deaths')
  } else{
    death_data = as.data.table( readRDS(path_to_JHU_data) )
  }

  # adjust for lag
  if(state_code %in% states_w_one_day_delay){
    dates_missing = dates_missing + 1
  }
  
  death_data = subset(death_data, code == state_code & date %in% dates_missing)
  tmp = merge(prop_deaths_df, death_data, by = 'code',allow.cartesian=TRUE)
  tmp[, daily.deaths := round(daily_deaths * prop.deaths)]
  tmp = select(tmp, code, date, age, daily.deaths)
  
  if(sum(tmp$daily.deaths) > max_deaths){
    tmp[, daily.deaths := floor(daily.deaths * max_deaths / (sum(tmp$daily.deaths)))]
  }
  
  # adjust for lag
  if(state_code %in% states_w_one_day_delay){
    tmp[, date := date - 1]
  }
  
  return(tmp)
}

generate_dailydeaths = function(n,s)
  {
  num = floor(s/n)
  nums = rep(num, n)
  i = n
  while(sum(nums) != s){
    nums[i] = nums[i] + 1
    i = i - 1
  }

 stopifnot(sum(nums) == s)
  
  return(nums)
}

`%notin%` = Negate(`%in%`)
