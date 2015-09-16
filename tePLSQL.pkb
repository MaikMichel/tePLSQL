CREATE OR REPLACE PACKAGE BODY teplsql
AS
   g_buffer   CLOB;

   PROCEDURE set_template_directive (p_directive IN CLOB, p_vars IN OUT t_assoc_array)
   AS
      l_key         VARCHAR2 (256);
      l_value       VARCHAR2 (256);
      l_directive   VARCHAR2 (32767);
   BEGIN
      l_directive := REGEXP_REPLACE (p_directive, '\s', '');

      FOR c1 IN (    SELECT   REGEXP_REPLACE (REGEXP_SUBSTR (l_directive
                                                           , '[^,]+'
                                                           , 1
                                                           , LEVEL), '\s', '')
                                 text
                       FROM   DUAL
                 CONNECT BY   REGEXP_SUBSTR (l_directive
                                           , '[^,]+'
                                           , 1
                                           , LEVEL) IS NOT NULL)
      LOOP         
         l_key       := SUBSTR (c1.text, 1, INSTR (c1.text, '=') - 1);         
         l_value     := SUBSTR (c1.text, INSTR (c1.text, '=') + 1);
         p_vars ('template_' || l_key) := l_value;
      END LOOP;
   END set_template_directive;

   PROCEDURE bind_vars (p_source IN OUT NOCOPY CLOB, p_vars IN t_assoc_array)
   AS
      l_key   VARCHAR2 (256);
   BEGIN
      IF p_vars.COUNT () <> 0
      THEN
         l_key       := p_vars.FIRST;

         LOOP
            EXIT WHEN l_key IS NULL;
            p_source    := REPLACE (p_source, '${' || l_key || '}', TO_CLOB (p_vars (l_key)));
            l_key       := p_vars.NEXT (l_key);
         END LOOP;
      END IF;
   END bind_vars;

   /*Parse template marks */
   PROCEDURE parse (p_source IN CLOB)
   AS
      l_open_count    PLS_INTEGER;
      l_close_count   PLS_INTEGER;
   BEGIN
      $if dbms_db_version.ver_le_10 $then
          /**
          *  ATTENTION, these instructions are very slow and penalize template processing time.
          *  If performance is critical to your system, you should disable the parser only for BD <= 10g
          */
          l_open_count :=
             NVL (LENGTH (REGEXP_REPLACE (p_source
                                        , '(<)%|.'
                                        , '\1'
                                        , 1
                                        , 0
                                        , 'n')), 0);

          l_close_count :=
             NVL (LENGTH (REGEXP_REPLACE (p_source
                                        , '(%)>|.'
                                        , '\1'
                                        , 1
                                        , 0
                                        , 'n')), 0);
      $else
          l_open_count := regexp_count (p_source, '<\%');
          l_close_count := regexp_count (p_source, '\%>');
      $end


      IF l_open_count <> l_close_count
      THEN
         raise_application_error (-20001
                                ,    '##Parser Exception: '
                                  || 'One or more tags (<% %>) are not closed: '
                                  || l_open_count
                                  || ' <> '
                                  || l_close_count
                                  || CHR (10));
      END IF;
   END parse;

   PROCEDURE PRINT (p_data IN CLOB)
   AS
   BEGIN
      g_buffer    := g_buffer || p_data;
   END PRINT;

   PROCEDURE PRINT (p_data IN VARCHAR2)
   AS
   BEGIN
      g_buffer    := g_buffer || p_data;
   END PRINT;

   PROCEDURE PRINT (p_data IN NUMBER)
   AS
   BEGIN
      g_buffer    := g_buffer || TO_CHAR (p_data);
   END PRINT;

   PROCEDURE p (p_data IN CLOB)
   AS
   BEGIN
      g_buffer    := g_buffer || p_data;
   END p;

   PROCEDURE p (p_data IN VARCHAR2)
   AS
   BEGIN
      g_buffer    := g_buffer || p_data;
   END p;

   PROCEDURE p (p_data IN NUMBER)
   AS
   BEGIN
      g_buffer    := g_buffer || TO_CHAR (p_data);
   END p;

   FUNCTION render (p_template IN CLOB, p_vars IN t_assoc_array DEFAULT null_assoc_array)
      RETURN CLOB
   AS
      l_template   CLOB := p_template;
      l_vars       t_assoc_array := p_vars;
      l_declare    CLOB;
      l_tmp        CLOB;
      i            PLS_INTEGER := 0;
   BEGIN
      --Clear buffer
      g_buffer    := NULL;

      --Parse <% %> tags
      parse (l_template);
            
      --Template directive
      $if dbms_db_version.ver_le_10 $then
          l_tmp       :=
             REPLACE (REPLACE (REGEXP_SUBSTR (l_template
                                            , '<%@ template([^%>].*?)%>'
                                            , 1
                                            , 1
                                            , 'n'), '<%@ template', ''), '%>', '');
      $else
          l_tmp       :=
             REGEXP_SUBSTR (l_template
                          , '<%@ template([^%>].*?)%>'
                          , 1
                          , 1
                          , 'n'
                          , 1);
      $end

      --Set template directive variables into var associative array
      set_template_directive (l_tmp, l_vars);

      --Bind the variables into template
      bind_vars (l_template, l_vars);
      
      --Null all variables not binded
      l_template    := REGEXP_REPLACE (l_template, '\$\{\S*\}', '');

      --Delete all template directives
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '<%@ template([^%>].*?)%>'
                       , ''
                       , 1
                       , 0
                       , 'n');

      --New lines.
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '(\\\\n)'
                       , CHR (10) --|| ']'');tePLSQL.p(q''['
                       , 1
                       , 0
                       , 'n');


      --Delete the line breaks for lines ending in %>[blanks]CHR(10)
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '(%>[[:blank:]]*?' || CHR (10) || ')'
                       , '%>'
                       , 1
                       , 0
                       , 'm');

      --Delete new lines with !\n
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '([[:blank:]]*\!\\n[[:blank:]]*' || CHR (10) || '?[[:blank:]]*)'
                       , ''
                       , 1
                       , 0
                       , 'm');

      -- Delete all blanks before <% in the beginning of each line
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '(^[[:blank:]]*<%)'
                       , '<%'
                       , 1
                       , 0
                       , 'm');
              
      --Merge all declaration blocks into a single block
      l_tmp       := NULL;

      LOOP
         i           := i + 1;
          $if dbms_db_version.ver_le_10 $then
             l_tmp       :=
                REPLACE (REPLACE (REGEXP_SUBSTR (l_template
                                               , '<%!([^%>].*?)%>'
                                               , 1
                                               , i
                                               , 'n'), '<%!', ''), '%>', '');
         $else
             l_tmp       :=
                REGEXP_SUBSTR (l_template
                             , '<%!([^%>].*?)%>'
                             , 1
                             , i
                             , 'n'
                             , 1);
         $end

         l_declare   := l_declare || l_tmp;
         EXIT WHEN LENGTH (l_tmp) = 0;
      END LOOP;

      --Delete declaration blocks from template
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '<%!([^%>].*?)%>'
                       , ''
                       , 1
                       , 0
                       , 'n');

      --Expresison directive
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '<%=([^%>].*?)%>'
                       , ']'');tePLSQL.p(\1);tePLSQL.p(q''['
                       , 1
                       , 0
                       , 'n');

      --Code blocks directive
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '<%([^%>].*?)%>'
                       , ']''); \1 tePLSQL.p(q''['
                       , 1
                       , 0
                       , 'n');

      --Escaped chars
      l_template  :=
         REGEXP_REPLACE (l_template
                       , '\\\\(.)'
                       , ']'');tePLSQL.p(q''[\1]'');tePLSQL.p(q''['
                       , 1
                       , 0
                       , 'n');


      l_template  := 'DECLARE ' || l_declare || ' BEGIN tePLSQL.p(q''[' || l_template || ' ]''); END;';

      --DBMS_OUTPUT.put_line (l_template);

      $if dbms_db_version.ver_le_10 $then
          --10g
          DECLARE
             v_upperbound   NUMBER;
             v_cur          INTEGER;
             v_sql          DBMS_SQL.varchar2a;
             v_ret          NUMBER;
          BEGIN
             v_upperbound := CEIL (DBMS_LOB.getlength (l_template) / 32767);

             FOR i IN 1 .. v_upperbound
             LOOP
                v_sql (i)   := DBMS_LOB.SUBSTR (l_template, -- clob statement
                                                  32767, -- amount
                                                  ( (i - 1) * 32767) + 1);
             END LOOP;

             v_cur       := DBMS_SQL.open_cursor;
             -- parse sql statement
             DBMS_SQL.parse (v_cur
                           , v_sql
                           , 1
                           , v_upperbound
                           , FALSE
                           , DBMS_SQL.native);
             -- execute
             v_ret       := DBMS_SQL.execute (v_cur);
          EXCEPTION
             WHEN OTHERS
             THEN
                --Print error
                PRINT ('### tePLSQL Render Error ###');
                PRINT (CHR (10));
                PRINT (SQLERRM || ' ' || DBMS_UTILITY.format_error_backtrace ());
                PRINT (CHR (10));
                PRINT ('### Processed template ###');
                PRINT (CHR (10));
                PRINT (l_template);
          END;

      $else
          -- 11g
          BEGIN
             EXECUTE IMMEDIATE l_template;
          EXCEPTION
             WHEN OTHERS
             THEN
                --Print error
                PRINT ('### tePLSQL Render Error ###');
                PRINT (CHR (10));
                PRINT (SQLERRM || ' ' || DBMS_UTILITY.format_error_backtrace ());
                PRINT (CHR (10));
                PRINT ('### Processed template ###');
                PRINT (CHR (10));
                PRINT (l_template);
          END;
      $end

      l_template  := g_buffer;
      g_buffer    := NULL;

      RETURN l_template;
   EXCEPTION
      WHEN OTHERS
      THEN
         raise_application_error (-20001, SQLERRM || ' ' || DBMS_UTILITY.format_error_backtrace ());
   END render;


   FUNCTION process (p_object_name     IN VARCHAR2
                   , p_vars            IN t_assoc_array DEFAULT null_assoc_array
                   , p_template_name   IN VARCHAR2 DEFAULT NULL
                   , p_object_type     IN VARCHAR2 DEFAULT 'PACKAGE'
                   , p_schema          IN VARCHAR2 DEFAULT NULL )
      RETURN CLOB
   AS
      l_result       CLOB;
      l_object_ddl   CLOB;
      l_template     CLOB;
      l_tmp          CLOB;
      i              PLS_INTEGER := 1;
      l_found        PLS_INTEGER := 0;
   BEGIN
      --Get package source DDL
      l_object_ddl := DBMS_METADATA.get_ddl (UPPER (p_object_type), UPPER (p_object_name), UPPER (p_schema));

      --If p_template_name is null get all templates from the object
      --else get only this template.
      IF p_template_name IS NOT NULL
      THEN
         LOOP
            l_tmp       :=
               REGEXP_SUBSTR (l_object_ddl
                            , '<%@ template([^%>].*?)%>'
                            , 1
                            , i
                            , 'n');
                            
            l_found     := INSTR (l_tmp, 'name='||p_template_name);

            EXIT WHEN LENGTH (l_tmp) = 0 OR l_found <> 0;
            i           := i + 1;
         END LOOP;
      ELSE
         l_found     := 0;
      END IF;
      
      -- i has the occurrence of the substr where the template is
      
      l_tmp       := NULL;      

      LOOP
         --Get Template from the object
         $if dbms_db_version.ver_le_10 $then
             l_tmp       :=
                REGEXP_REPLACE (REGEXP_REPLACE (REGEXP_SUBSTR (l_object_ddl
                                                             , '\$if false \$then' || CHR (10) || '([^\$end].*?)\$end'
                                                             , 1
                                                             , i
                                                             , 'n')
                                              , '\$if false \$then' || CHR (10)
                                              , ''
                                              , 1
                                              , 1)
                              , '\$end'
                              , ''
                              , 1
                              , INSTR ('$end', 1, -1));
         $else
             l_tmp       :=
                REGEXP_SUBSTR (l_object_ddl
                             , '\$if false \$then' || CHR (10) || '([^\$end].*?)\$end'
                             , 1
                             , i
                             , 'n'
                             , 1);
         $end

         l_template  := l_template || l_tmp;
         EXIT WHEN LENGTH (l_tmp) = 0 OR l_found <> 0;
         i           := i + 1;
      END LOOP;

      IF LENGTH (l_template) = 0
      THEN
         IF p_template_name IS NOT NULL
         THEN
            raise_application_error (-20002
                                   , 'Template ' || p_template_name || ' not found in object ' || UPPER (p_object_name));
         ELSE
            raise_application_error (-20002
                                   , 'The object ' || l_object_ddl || ' have no template inside $if false $then');
         END IF;
      END IF;

      --Render template
      l_result    := teplsql.render (l_template, p_vars);
      RETURN l_result;
   END process;
END teplsql;
/