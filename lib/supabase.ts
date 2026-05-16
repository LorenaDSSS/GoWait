import { createClient } from "@supabase/supabase-js";

const supabaseUrl = "https://mfhienxxxaeyerjaoovx.supabase.co";
const supabaseKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1maGllbnh4eGFleWVyamFvb3Z4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4ODg5MTAsImV4cCI6MjA5NDQ2NDkxMH0.i-d6A4T7yK3obqNAN2zNVkv_KrHQWBK0Kwv-KpIdkI8";

export const supabase = createClient(supabaseUrl, supabaseKey);